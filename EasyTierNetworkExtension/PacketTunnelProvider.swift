import os
import NetworkExtension
import Network
import Foundation

import EasyTierShared

let loggerSubsystem = "\(APP_BUNDLE_ID).tunnel"
let debounceInterval = 0.5
let logger = Logger(subsystem: loggerSubsystem, category: "swift")

private struct ProviderMessageResponse: Codable {
    let ok: Bool
    let path: String?
    let error: String?
}

private final class OneShotErrorCompletion {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard let handler else {
            lock.unlock()
            return
        }
        self.handler = nil
        lock.unlock()
        handler(error)
    }
}

private struct PendingStartCompletion {
    let generation: UInt64
    let completion: OneShotErrorCompletion
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    // Hold a weak reference to the current provider for C callback bridging
    private static weak var current: PacketTunnelProvider?
    private let settingsQueue = DispatchQueue(label: "\(APP_BUNDLE_ID).tunnel.settings")
    private var tunnelGeneration: UInt64 = 0
    private var activeTunnelGeneration: UInt64?
    private var settingsApplyGeneration: UInt64?
    private var pendingStartCompletion: PendingStartCompletion?
    private var lastOptions: EasyTierOptions?
    private var lastAppliedSettings: TunnelNetworkSettingsSnapshot?
    private var needReapplySettings: Bool = false

    // MARK: - Memory probe
    //
    // iOS enforces a fixed per-process memory budget on a packet tunnel provider and
    // has jetsam kill it on breach. The kill is silent: no crash log is produced, the
    // host app survives, and the user only sees the tunnel drop. Apple DTS has quoted
    // 50 MiB for iOS 15/16 on the developer forums, but that figure is undocumented,
    // has moved across releases (5 -> 15 -> 50), and nothing is published for iOS 17
    // or later -- so it has to be measured on the target device, never assumed.
    //
    // We sample phys_footprint, which is the same ledger jetsam charges against and
    // the reason resident_size alone would be misleading. Logging it on a timer lets
    // a long session show how much headroom the EasyTier core actually leaves before
    // any further component is linked into this same process.
    private static let memoryProbeInterval: TimeInterval = 15
    private var memoryProbeTimer: DispatchSourceTimer?
    private var memoryPeakBytes: UInt64 = 0
    private var memoryProbeStartedAt: Date?

    private static func sampleMemory() -> (footprint: UInt64, resident: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.phys_footprint), info.resident_size)
    }

    // Emitted at .warning on purpose: OSLog does not persist .info or .debug, so
    // anything logged below .warning would be gone by the time the log is exported.
    private func logMemory(_ tag: String) {
        guard let sample = PacketTunnelProvider.sampleMemory() else {
            logger.error("memProbe(\(tag, privacy: .public)) task_info failed")
            return
        }
        if sample.footprint > memoryPeakBytes {
            memoryPeakBytes = sample.footprint
        }
        let mib = 1024.0 * 1024.0
        let elapsed = memoryProbeStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        // pctOf50MiB is a reading aid only; nothing branches on it, precisely because
        // the real budget is undocumented and varies by iOS version.
        let line = String(
            format: "memProbe(%@) t=%lds footprint=%.2fMiB peak=%.2fMiB resident=%.2fMiB pctOf50MiB=%.1f%%",
            tag,
            elapsed,
            Double(sample.footprint) / mib,
            Double(memoryPeakBytes) / mib,
            Double(sample.resident) / mib,
            Double(sample.footprint) / (50.0 * mib) * 100.0
        )
        logger.warning("\(line, privacy: .public)")
    }

    private func startMemoryProbe() {
        stopMemoryProbe()
        memoryProbeStartedAt = Date()
        memoryPeakBytes = 0
        logMemory("start")
        let timer = DispatchSource.makeTimerSource(queue: settingsQueue)
        timer.schedule(
            deadline: .now() + PacketTunnelProvider.memoryProbeInterval,
            repeating: PacketTunnelProvider.memoryProbeInterval
        )
        timer.setEventHandler { [weak self] in
            self?.logMemory("tick")
        }
        timer.resume()
        memoryProbeTimer = timer
    }

    private func stopMemoryProbe() {
        guard memoryProbeTimer != nil else { return }
        logMemory("stop")
        memoryProbeTimer?.cancel()
        memoryProbeTimer = nil
        memoryProbeStartedAt = nil
    }

    private func resetTunnelSessionState() {
        lastOptions = nil
        lastAppliedSettings = nil
        needReapplySettings = false
        settingsApplyGeneration = nil
        reasserting = false
    }

    private func completeStart(generation: UInt64, error: Error?) {
        guard let pendingStartCompletion,
              pendingStartCompletion.generation == generation else {
            return
        }
        self.pendingStartCompletion = nil
        pendingStartCompletion.completion.finish(error)
    }

    private func failStart(generation: UInt64, error: Error, stopNetwork: Bool) {
        guard activeTunnelGeneration == generation else {
            completeStart(generation: generation, error: error)
            return
        }

        activeTunnelGeneration = nil
        resetTunnelSessionState()
        if PacketTunnelProvider.current === self {
            PacketTunnelProvider.current = nil
        }
        if stopNetwork, stop_network_instance() != 0 {
            logger.error("failStart() failed to stop network instance")
        }
        completeStart(generation: generation, error: error)
    }
    
    private func postDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }
    
    private func notifyHostAppError(_ message: String) {
        // Persist the latest error into shared defaults so the host app can read details
        if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
            defaults.set(message, forKey: "TunnelLastError")
            defaults.synchronize()
        }
        // Wake the host app via Darwin notification
        postDarwinNotification("\(APP_BUNDLE_ID).error")
    }
    
    private func registerRunningInfoCallback() {
        let infoChangedCallback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRunningInfoChanged()
        }
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = register_running_info_callback(infoChangedCallback, &errPtr)
        if ret != 0 {
            let err = extractRustString(errPtr)
            logger.error("registerRunningInfoCallback() failed: \(err ?? "Unknown", privacy: .public)")
        } else {
            logger.info("registerRunningInfoCallback() registered")
        }
    }

    private func handleRunningInfoChanged() {
        logger.warning("handleRunningInfoChanged(): triggered")
        enqueueSettingsUpdate()
    }
    
    private func registerRustStopCallback() {
        // Register FFI stop callback to capture crashes/stop events
        let rustStopCallback: @convention(c) () -> Void = {
            PacketTunnelProvider.current?.handleRustStop()
        }
        var regErrPtr: UnsafePointer<CChar>? = nil
        let regRet = register_stop_callback(rustStopCallback, &regErrPtr)
        if regRet != 0 {
            let regErr = extractRustString(regErrPtr)
            logger.error("startTunnel() failed to register stop callback: \(regErr ?? "Unknown", privacy: .public)")
        } else {
            logger.info("startTunnel() registered FFI stop callback")
        }
    }
    
    private func handleRustStop() {
        // Called from FFI callback on an arbitrary thread
        var msgPtr: UnsafePointer<CChar>? = nil
        var errPtr: UnsafePointer<CChar>? = nil
        let ret = get_latest_error_msg(&msgPtr, &errPtr)
        if ret == 0, let msg = extractRustString(msgPtr) {
            logger.error("handleRustStop(): \(msg, privacy: .public)")
            // Inform host app and cancel the tunnel on global queue
            DispatchQueue.main.async {
                self.notifyHostAppError(msg)
                self.cancelTunnelWithError(msg)
            }
        } else if let err = extractRustString(errPtr) {
            logger.error("handleRustStop() failed to get latest error: \(err, privacy: .public)")
        }
    }

    private func enqueueSettingsUpdate() {
        settingsQueue.async { [weak self] in
            guard let self else { return }
            guard let generation = self.activeTunnelGeneration else {
                logger.info("enqueueSettingsUpdate() ignored without an active tunnel")
                return
            }
            if self.settingsApplyGeneration == generation {
                logger.info("enqueueSettingsUpdate() update in progress, waiting")
                self.needReapplySettings = true
                return
            }
            logger.info("enqueueSettingsUpdate() starting settings update")
            self.applyNetworkSettings(generation: generation) { error in
                guard let error else { return }
                logger.error("enqueueSettingsUpdate() failed with error: \(error, privacy: .public)")
            }
        }
    }

    private func applyNetworkSettings(
        generation: UInt64,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard activeTunnelGeneration == generation else {
            completion("tunnel session is no longer active")
            return
        }
        guard settingsApplyGeneration == nil else {
            logger.error("applyNetworkSettings() still in progress")
            completion("still in progress")
            return
        }
        settingsApplyGeneration = generation
        needReapplySettings = false
        reasserting = true

        settingsQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self else {
                completion("packet tunnel provider was deallocated")
                return
            }
            guard self.activeTunnelGeneration == generation,
                  self.settingsApplyGeneration == generation else {
                completion("tunnel session is no longer active")
                return
            }
            guard let options = self.lastOptions else {
                logger.error("applyNetworkSettings() cannot get options")
                self.finishNetworkSettingsApply(
                    generation: generation,
                    snapshot: nil,
                    error: "cannot get options",
                    completion: completion
                )
                return
            }

            let settings = buildSettings(options)
            let newSnapshot = self.snapshotSettings(settings)
            if newSnapshot == self.lastAppliedSettings {
                logger.warning("applyNetworkSettings() new settings are exactly the same as last applied, skipping")
                self.finishNetworkSettingsApply(
                    generation: generation,
                    snapshot: newSnapshot,
                    error: nil,
                    completion: completion
                )
                return
            }

            let needSetTunFd = self.shouldUpdateTunFd(old: self.lastAppliedSettings, new: newSnapshot)
            logger.info("applyNetworkSettings() need set tunfd: \(needSetTunFd), settings: \(settings, privacy: .public)")
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else {
                    completion(error ?? "packet tunnel provider was deallocated")
                    return
                }
                self.settingsQueue.async {
                    guard self.activeTunnelGeneration == generation,
                          self.settingsApplyGeneration == generation else {
                        completion("tunnel session is no longer active")
                        return
                    }
                    if let error {
                        logger.error("applyNetworkSettings() failed to set tunnel settings: \(error, privacy: .public)")
                        self.notifyHostAppError(error.localizedDescription)
                        self.finishNetworkSettingsApply(
                            generation: generation,
                            snapshot: newSnapshot,
                            error: error,
                            completion: completion
                        )
                        return
                    }
                    if needSetTunFd {
                        guard let tunFd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32
                                ?? tunnelFileDescriptor() else {
                            let message = "no available tun fd"
                            logger.error("applyNetworkSettings() no available tun fd")
                            self.notifyHostAppError(message)
                            self.finishNetworkSettingsApply(
                                generation: generation,
                                snapshot: newSnapshot,
                                error: message,
                                completion: completion
                            )
                            return
                        }
                        logger.info("applyNetworkSettings() found fd: \(tunFd, privacy: .public)")
                        guard setNonBlocking(fd: tunFd) else {
                            let message = "failed to set tun fd non-blocking"
                            logger.error("applyNetworkSettings() failed to set fd \(tunFd, privacy: .public) non-blocking")
                            self.notifyHostAppError(message)
                            self.finishNetworkSettingsApply(
                                generation: generation,
                                snapshot: newSnapshot,
                                error: message,
                                completion: completion
                            )
                            return
                        }
                        var errPtr: UnsafePointer<CChar>? = nil
                        let ret = set_tun_fd(tunFd, &errPtr)
                        guard ret == 0 else {
                            let message = extractRustString(errPtr) ?? "Unknown"
                            logger.error("applyNetworkSettings() failed to set tun fd to \(tunFd): \(message, privacy: .public)")
                            self.notifyHostAppError(message)
                            self.finishNetworkSettingsApply(
                                generation: generation,
                                snapshot: newSnapshot,
                                error: message,
                                completion: completion
                            )
                            return
                        }
                    }
                    logger.info("applyNetworkSettings() settings applied")
                    self.logMemory("settingsApplied")
                    self.finishNetworkSettingsApply(
                        generation: generation,
                        snapshot: newSnapshot,
                        error: nil,
                        completion: completion
                    )
                }
            }
        }
    }

    private func finishNetworkSettingsApply(
        generation: UInt64,
        snapshot: TunnelNetworkSettingsSnapshot?,
        error: Error?,
        completion: @escaping (Error?) -> Void
    ) {
        guard activeTunnelGeneration == generation,
              settingsApplyGeneration == generation else {
            completion(error ?? "tunnel session is no longer active")
            return
        }

        if error == nil, let snapshot {
            lastAppliedSettings = snapshot
        }
        let shouldReapply = needReapplySettings
        needReapplySettings = false
        settingsApplyGeneration = nil
        reasserting = false
        completion(error)

        guard shouldReapply else { return }
        settingsQueue.async { [weak self] in
            guard let self,
                  self.activeTunnelGeneration == generation,
                  self.settingsApplyGeneration == nil else {
                return
            }
            self.applyNetworkSettings(generation: generation) { error in
                guard let error else { return }
                logger.error("applyNetworkSettings() deferred update failed: \(error, privacy: .public)")
            }
        }
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.warning("startTunnel(): triggered")
        let completion = OneShotErrorCompletion(completionHandler)
        settingsQueue.async {
            self.tunnelGeneration &+= 1
            let generation = self.tunnelGeneration

            if let pendingStartCompletion = self.pendingStartCompletion {
                self.pendingStartCompletion = nil
                pendingStartCompletion.completion.finish("tunnel start was superseded")
            }
            self.resetTunnelSessionState()
            self.activeTunnelGeneration = generation
            self.pendingStartCompletion = .init(generation: generation, completion: completion)
            PacketTunnelProvider.current = self

            let defaults = UserDefaults(suiteName: APP_GROUP_ID)
            guard let configData = defaults?.data(forKey: "VPNConfig"),
                  let options = try? JSONDecoder().decode(EasyTierOptions.self, from: configData) else {
                let message = "options is nil"
                logger.error("startTunnel() options is nil")
                self.notifyHostAppError(message)
                self.failStart(generation: generation, error: message, stopNetwork: false)
                return
            }
            self.lastOptions = options

            initRustLogger(level: options.logLevel)
            var errPtr: UnsafePointer<CChar>? = nil
            let ret = options.config.withCString { strPtr in
                return run_network_instance(strPtr, &errPtr)
            }
            guard ret == 0 else {
                let message = extractRustString(errPtr) ?? "Unknown"
                logger.error("startTunnel() failed to run: \(message, privacy: .public)")
                self.notifyHostAppError(message)
                self.failStart(generation: generation, error: message, stopNetwork: false)
                return
            }
            self.registerRustStopCallback()
            self.registerRunningInfoCallback()
            self.applyNetworkSettings(generation: generation) { error in
                guard self.activeTunnelGeneration == generation else {
                    self.completeStart(
                        generation: generation,
                        error: error ?? "tunnel session is no longer active"
                    )
                    return
                }
                if let error {
                    self.failStart(generation: generation, error: error, stopNetwork: true)
                } else {
                    self.startMemoryProbe()
                    self.completeStart(generation: generation, error: nil)
                }
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.warning("stopTunnel(): triggered")
        settingsQueue.async {
            self.stopMemoryProbe()
            self.tunnelGeneration &+= 1
            self.activeTunnelGeneration = nil
            let pendingStartCompletion = self.pendingStartCompletion
            self.pendingStartCompletion = nil
            self.resetTunnelSessionState()
            if PacketTunnelProvider.current === self {
                PacketTunnelProvider.current = nil
            }

            let ret = stop_network_instance()
            if ret != 0 {
                logger.error("stopTunnel() failed")
            }
            pendingStartCompletion?.completion.finish("tunnel stopped before startup completed")
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        logger.debug("handleAppMessage(): triggered")
        // Add code here to handle the message.
        guard let completionHandler else { return }
        if let raw = String(data: messageData, encoding: .utf8),
           let command = ProviderCommand(rawValue: raw) {
            switch command {
            case .clearLog:
                var errPtr: UnsafePointer<CChar>? = nil
                if clear_logger(&errPtr) == 0 {
                    let response = ProviderMessageResponse(ok: true, path: nil, error: nil)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                } else {
                    let err = extractRustString(errPtr) ?? "Unknown"
                    logger.error("handleAppMessage() clear logger failed: \(err, privacy: .public)")
                    let response = ProviderMessageResponse(ok: false, path: nil, error: err)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                }
            case .exportOSLog:
                do {
                    let url = try OSLogExporter.exportToAppGroup(appGroupID: APP_GROUP_ID)
                    let response = ProviderMessageResponse(ok: true, path: url.path, error: nil)
                    let data = try JSONEncoder().encode(response)
                    completionHandler(data)
                } catch {
                    let response = ProviderMessageResponse(ok: false, path: nil, error: error.localizedDescription)
                    let data = try? JSONEncoder().encode(response)
                    completionHandler(data)
                }
            case .runningInfo:
                var infoPtr: UnsafePointer<CChar>? = nil
                var errPtr: UnsafePointer<CChar>? = nil
                if get_running_info(&infoPtr, &errPtr) == 0, let info = extractRustString(infoPtr) {
                    completionHandler(info.data(using: .utf8))
                } else if let err = extractRustString(errPtr) {
                    logger.error("handleAppMessage() failed: \(err, privacy: .public)")
                    completionHandler(nil)
                } else {
                    completionHandler(nil)
                }
            case .lastNetworkSettings:
                settingsQueue.async { [weak self] in
                    guard let lastAppliedSettings = self?.lastAppliedSettings else {
                        completionHandler(nil)
                        return
                    }
                    do {
                        let data = try JSONEncoder().encode(lastAppliedSettings)
                        completionHandler(data)
                    } catch {
                        logger.error("handleAppMessage() encode settings failed: \(error, privacy: .public)")
                        completionHandler(nil)
                    }
                }
            }
            return
        }
        completionHandler(nil)
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
}

extension String: @retroactive Error {}
