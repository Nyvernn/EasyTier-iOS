import os
import NetworkExtension
import Network
import Foundation

import EasyTierShared

let loggerSubsystem = "\(APP_BUNDLE_ID).tunnel"
let debounceInterval = 0.5
let logger = Logger(subsystem: loggerSubsystem, category: "swift")

/// In-process ring buffer, retrievable through the `diagnostics` provider message.
///
/// Every other way of getting logs off the device is unavailable on a re-signed
/// build: the Rust log file and the OSLog export both live in the App Group
/// container, whose entitlement a third-party certificate invalidates, and telemetry
/// over the overlay cannot help diagnose the overlay itself. That coupling between
/// the diagnostic channel and the thing being diagnosed is what this avoids -- it
/// depends on nothing but the provider message channel.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 4000
    private let startedAt = Date()

    func append(_ message: String) {
        let elapsed = String(format: "%8.2f", Date().timeIntervalSince(startedAt))
        lock.lock()
        lines.append("[\(elapsed)] \(message)")
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        lock.unlock()
    }

    func dump() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return "diag build: \(DIAG_BUILD)\n" + snapshot.joined(separator: "\n")
    }
}

/// Bumped by hand on every diagnostics change, so an exported log always states
/// which build produced it. Comparing bundle versions is not enough: the CI hands
/// out the same version string for every commit.
let DIAG_BUILD = "diag-2 (route merge)"

/// Log to OSLog and to the retrievable buffer at once.
///
/// `.warning` because OSLog drops `.info` and `.debug` without persisting them, so
/// anything below that would be gone by the time a properly signed build exports it.
func dlog(_ message: String) {
    logger.warning("\(message, privacy: .public)")
    DiagnosticsLog.shared.append(message)
}

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
        // Into the retrievable buffer as well as out over the network: telemetry can be
        // lost to a routing problem, and the measurements are the whole point -- they
        // must not depend solely on the channel that is itself under suspicion.
        dlog(line)
        sendTelemetry(line)
    }

    private func startMemoryProbe() {
        stopMemoryProbe()
        memoryProbeStartedAt = Date()
        memoryPeakBytes = 0
        dlog("startMemoryProbe() interval=\(PacketTunnelProvider.memoryProbeInterval)s")
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

    // MARK: - Load generator
    //
    // Waiting for ordinary usage to reveal the ceiling is too slow and misses the
    // point: the dominant memory cost is the number of concurrent connections (each
    // carries its own send/receive buffers), and a browser only opens 6-8 of them.
    //
    // So once the tunnel is up we drive a staged load through it, stepping the
    // concurrency up and sampling footprint at every step. The resulting
    // concurrency-to-memory curve is what tells us how much headroom is left for a
    // tun->socks5 stack later, and it is also what pins down the buffer sizes and
    // connection caps that such a stack has to be compiled with.
    //
    // The target needs to be a TCP service on the far side that keeps echoing, and
    // defaults to the host address exposed through EasyTier's subnet proxy. Override
    // it by writing StressTarget ("host:port") into the App Group defaults. The run
    // stops by itself after the last stage -- roughly three minutes total -- and
    // sampling then continues at the idle interval.
    private static let stressStages: [Int] = [8, 32, 96, 192]
    private static let stressStageSeconds: TimeInterval = 40
    private static let stressStartDelaySeconds: TimeInterval = 45
    private static let stressPayload = Data(count: 4096)
    private static let stressDefaultTarget = "192.168.65.254:8899"

    private var stressConnections: [NWConnection] = []
    private var stressActive = false
    private var stressBytesOut: UInt64 = 0
    private var stressBytesIn: UInt64 = 0
    private var stressReady = 0
    private var stressFailed = 0

    // All NWConnection callbacks below are delivered on settingsQueue (see the
    // conn.start(queue:) call), which is also where the counters are mutated, so no
    // further synchronisation is needed.
    private func parseStressTarget() -> (host: String, port: UInt16)? {
        let raw = UserDefaults(suiteName: APP_GROUP_ID)?.string(forKey: "StressTarget")
            ?? PacketTunnelProvider.stressDefaultTarget
        guard let separator = raw.lastIndex(of: ":") else { return nil }
        let host = String(raw[raw.startIndex..<separator])
        guard !host.isEmpty, let port = UInt16(raw[raw.index(after: separator)...]) else {
            return nil
        }
        return (host, port)
    }

    private func scheduleStressTest() {
        settingsQueue.asyncAfter(
            deadline: .now() + PacketTunnelProvider.stressStartDelaySeconds
        ) { [weak self] in
            guard let self, self.activeTunnelGeneration != nil, !self.stressActive else { return }
            guard let target = self.parseStressTarget() else {
                dlog("stress skipped: StressTarget is not a valid host:port")
                return
            }
            self.stressActive = true
            let line = "stress begin target=\(target.host):\(target.port) stages=\(PacketTunnelProvider.stressStages)"
            dlog(line)
            self.runStressStage(0, target: target)
        }
    }

    private func runStressStage(_ index: Int, target: (host: String, port: UInt16)) {
        guard stressActive, activeTunnelGeneration != nil,
              index < PacketTunnelProvider.stressStages.count,
              let port = NWEndpoint.Port(rawValue: target.port) else {
            finishStress()
            return
        }

        closeStressConnections()
        stressReady = 0
        stressFailed = 0
        let concurrency = PacketTunnelProvider.stressStages[index]
        logMemory("stressBegin-c\(concurrency)")

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(target.host), port: port)
        for _ in 0..<concurrency {
            let conn = NWConnection(to: endpoint, using: .tcp)
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, self.stressActive else { return }
                switch state {
                case .ready:
                    self.stressReady += 1
                    self.pumpStress(conn)
                case .failed(let error):
                    self.stressFailed += 1
                    // First few only -- with 192 connections failing for one shared
                    // reason, the rest add nothing but noise.
                    if self.stressFailed <= 3 {
                        DiagnosticsLog.shared.append(
                            "stress conn failed (#\(self.stressFailed)): \(error)"
                        )
                    }
                case .cancelled:
                    self.stressFailed += 1
                default:
                    break
                }
            }
            stressConnections.append(conn)
            conn.start(queue: settingsQueue)
        }

        settingsQueue.asyncAfter(
            deadline: .now() + PacketTunnelProvider.stressStageSeconds
        ) { [weak self] in
            guard let self else { return }
            let line = String(
                format: "stressEnd-c%d ready=%d failed=%d out=%.1fMiB in=%.1fMiB",
                concurrency,
                self.stressReady,
                self.stressFailed,
                Double(self.stressBytesOut) / 1048576.0,
                Double(self.stressBytesIn) / 1048576.0
            )
            dlog(line)
            self.sendTelemetry(line)
            self.logMemory("stressEnd-c\(concurrency)")
            self.runStressStage(index + 1, target: target)
        }
    }

    private func pumpStress(_ conn: NWConnection) {
        guard stressActive else { return }
        conn.send(
            content: PacketTunnelProvider.stressPayload,
            completion: .contentProcessed { [weak self] error in
                guard let self, self.stressActive, error == nil else { return }
                self.stressBytesOut += UInt64(PacketTunnelProvider.stressPayload.count)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) {
                    [weak self] data, _, isComplete, error in
                    guard let self, self.stressActive else { return }
                    if let data, !data.isEmpty {
                        self.stressBytesIn += UInt64(data.count)
                    }
                    guard error == nil, !isComplete else { return }
                    self.pumpStress(conn)
                }
            }
        )
    }

    private func closeStressConnections() {
        for conn in stressConnections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        stressConnections.removeAll()
    }

    private func finishStress() {
        guard stressActive else { return }
        stressActive = false
        closeStressConnections()
        logMemory("stressDone")
        logger.warning("stress finished, returning to idle sampling")
    }

    // MARK: - Reachability preflight
    //
    // Both the telemetry sink and the load target sit behind the peer's proxied subnet,
    // so when neither answers there is no way to tell which layer broke. These three
    // targets separate them, and the pattern of which ones connect is the diagnosis:
    //
    //   overlay   the peer's virtual IP, port 11010 -- EasyTier's own listener, always
    //             up, needs no setup on the far side. Answers only if outbound traffic
    //             actually leaves through the tun device and reaches the peer.
    //   proxied   the address behind the peer's --proxy-networks. Answers only if that
    //             CIDR reached includedRoutes *and* the peer forwards it. Verified
    //             working from another overlay node, so a failure here is iOS-side.
    //   internet  outside the tunnel entirely. Answers regardless, so if even this one
    //             fails the probe itself is at fault and the other two prove nothing.
    //
    // Repeated a few times because proxy CIDRs arrive by route propagation: the first
    // round can legitimately fail while a later one succeeds, and that difference is
    // itself the answer.
    private static let preflightTargets: [(label: String, host: String, port: UInt16)] = [
        ("overlay", "10.144.144.1", 11010),
        ("proxied", "192.168.65.254", 8899),
        ("internet", "1.1.1.1", 443),
    ]
    // Spaced to land almost entirely before the load test starts at 45s: three probe
    // sockets are nothing next to 192, but keeping them out of the way leaves the
    // footprint samples attributable to the stage that produced them.
    private static let preflightRounds = 4
    private static let preflightFirstDelaySeconds: TimeInterval = 10
    private static let preflightIntervalSeconds: TimeInterval = 15
    private static let preflightTimeoutSeconds: TimeInterval = 8

    private func schedulePreflight() {
        for round in 0..<PacketTunnelProvider.preflightRounds {
            let delay = PacketTunnelProvider.preflightFirstDelaySeconds
                + Double(round) * PacketTunnelProvider.preflightIntervalSeconds
            settingsQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.activeTunnelGeneration != nil else { return }
                self.runPreflight(round: round)
            }
        }
    }

    private func runPreflight(round: Int) {
        for target in PacketTunnelProvider.preflightTargets {
            guard let port = NWEndpoint.Port(rawValue: target.port) else { continue }
            let name = "preflight[\(round)] \(target.label) \(target.host):\(target.port)"
            let conn = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(target.host), port: port),
                using: .tcp
            )
            var settled = false
            var waitingLogged = false
            let queue = settingsQueue
            // The handler has to be released, or it keeps the connection alive and a
            // dozen leaked sockets end up in the very footprint being measured. Doing
            // it on a later turn of the queue rather than inline: `finish` runs from
            // inside that same handler, and dropping the last reference to a closure
            // while it is executing is not something to rely on.
            let finish: (String) -> Void = { outcome in
                guard !settled else { return }
                settled = true
                dlog("\(name) -> \(outcome)")
                conn.cancel()
                queue.async { conn.stateUpdateHandler = nil }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish("ready")
                case .failed(let error):
                    finish("failed: \(error)")
                case .waiting(let error):
                    guard !waitingLogged else { return }
                    waitingLogged = true
                    dlog("\(name) waiting: \(error)")
                default:
                    break
                }
            }
            conn.start(queue: settingsQueue)
            settingsQueue.asyncAfter(
                deadline: .now() + PacketTunnelProvider.preflightTimeoutSeconds
            ) {
                finish("timeout")
            }
        }
    }

    // MARK: - Configuration channels
    //
    // Configuration reaches this extension by two routes, and both have to be tried:
    //
    //   1. VPNConfig in the App Group container -- upstream's only channel. Re-signing
    //      the IPA with a third-party shared certificate invalidates the
    //      group.cn.easytier entitlement, after which UserDefaults(suiteName:) no
    //      longer resolves to a shared container and this route is simply gone.
    //   2. providerConfiguration -- a dictionary carried by NETunnelProviderProtocol,
    //      persisted by the system alongside the VPN configuration itself. It does not
    //      involve the App Group, so it still works on a re-signed build.
    //
    // Losing route 1 used to fail in the worst possible way: everything that would
    // have reported it lives in the same container (the error hand-back, the Rust log
    // file, the OSLog export), so the only symptom was a VPN icon blinking once.
    //
    // Deliberately NOT hardcoding network credentials as a fallback: this is a public
    // repository, and a committed network_secret would let anyone join the overlay --
    // where members can not only borrow the exit but also reach the host's RDP port.
    private func loadOptions() -> EasyTierOptions? {
        if let data = UserDefaults(suiteName: APP_GROUP_ID)?.data(forKey: "VPNConfig"),
           let decoded = try? JSONDecoder().decode(EasyTierOptions.self, from: data) {
            dlog("loadOptions() read from App Group")
            return decoded
        }

        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let raw = tunnelProtocol.providerConfiguration?["options"] else {
            return nil
        }
        // The system round-trips providerConfiguration values through its own
        // serialisation, so a Data may come back as a base64 string.
        let data: Data?
        if let direct = raw as? Data {
            data = direct
        } else if let text = raw as? String {
            data = Data(base64Encoded: text) ?? text.data(using: .utf8)
        } else {
            data = nil
        }
        guard let data,
              let decoded = try? JSONDecoder().decode(EasyTierOptions.self, from: data) else {
            logger.error("loadOptions() providerConfiguration present but not decodable")
            return nil
        }
        dlog("loadOptions() App Group unreadable -> fell back to providerConfiguration")
        return decoded
    }

    // MARK: - Telemetry over the tunnel
    //
    // With the App Group gone, both log sinks land in a container nobody can read, so
    // the measurements are shipped straight to the peer instead. This also doubles as
    // a liveness check on the tunnel itself: telemetry arriving at all proves the
    // overlay carries traffic.
    //
    // UDP on purpose -- it is stateless, so losing a sample or two costs nothing and
    // there is no reconnect logic to maintain inside a memory-constrained process.
    private static let telemetryTarget = "192.168.65.254:8897"
    private var telemetryConnection: NWConnection?
    private var telemetryErrorCount = 0

    private static func parseHostPort(_ raw: String) -> (host: String, port: UInt16)? {
        guard let separator = raw.lastIndex(of: ":") else { return nil }
        let host = String(raw[raw.startIndex..<separator])
        guard !host.isEmpty, let port = UInt16(raw[raw.index(after: separator)...]) else {
            return nil
        }
        return (host, port)
    }

    private func sendTelemetry(_ line: String) {
        if telemetryConnection == nil {
            guard let target = PacketTunnelProvider.parseHostPort(
                PacketTunnelProvider.telemetryTarget
            ), let port = NWEndpoint.Port(rawValue: target.port) else { return }
            let conn = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(target.host), port: port),
                using: .udp
            )
            conn.stateUpdateHandler = { state in
                // Even UDP reports state here, and "waiting" with a routing error is
                // exactly the signature of the route never having been installed.
                DiagnosticsLog.shared.append("telemetry conn state: \(state)")
            }
            conn.start(queue: settingsQueue)
            telemetryConnection = conn
            dlog("telemetry opened to \(target.host):\(target.port)")
        }
        guard let conn = telemetryConnection,
              let data = (line + "\n").data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            // Only the first few: the failure mode is identical every time, and one
            // entry per 15s sample would bury everything else in the buffer.
            guard self.telemetryErrorCount < 3 else { return }
            self.telemetryErrorCount += 1
            DiagnosticsLog.shared.append(
                "telemetry send failed (#\(self.telemetryErrorCount)): \(error)"
            )
        })
    }

    private func closeTelemetry() {
        telemetryConnection?.cancel()
        telemetryConnection = nil
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
            // Reachability of a proxied subnet (the peer's 192.168.65.254, say) hinges
            // entirely on what lands in includedRoutes here: without a matching entry
            // iOS never hands those packets to the tun device, and they leak out over
            // cellular to an address that does not exist there. So log verbatim what
            // actually got applied.
            let appliedRoutes = (settings.ipv4Settings?.includedRoutes ?? [])
                .map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }
                .joined(separator: ", ")
            dlog("applyNetworkSettings() addrs=\(settings.ipv4Settings?.addresses ?? []) includedRoutes=[\(appliedRoutes)]")
            if newSnapshot == self.lastAppliedSettings {
                // Worth flagging loudly: if the snapshot type does not cover routes,
                // a route-only update would be mistaken for "no change" and dropped.
                dlog("applyNetworkSettings() snapshot unchanged -> SKIPPING re-apply")
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

            guard let options = self.loadOptions() else {
                // Both channels came up empty. Note this point is still ahead of
                // initRustLogger, so nothing below .warning would survive anywhere --
                // hence the explicit message rather than the original "options is nil".
                let message = "no configuration: App Group unreadable and providerConfiguration empty"
                logger.error("startTunnel() \(message, privacy: .public)")
                self.notifyHostAppError(message)
                self.failStart(generation: generation, error: message, stopNetwork: false)
                return
            }
            self.lastOptions = options
            dlog("startTunnel() options ipv4=\(options.ipv4 ?? "-") mtu=\(options.mtu.map(String.init) ?? "-") manualRoutes=\(options.routes.count) configBytes=\(options.config.count) logLevel=\(options.logLevel.rawValue)")

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
                    self.schedulePreflight()
                    self.scheduleStressTest()
                    self.completeStart(generation: generation, error: nil)
                }
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.warning("stopTunnel(): triggered")
        settingsQueue.async {
            self.finishStress()
            self.stopMemoryProbe()
            self.closeTelemetry()
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
            case .diagnostics:
                var text = DiagnosticsLog.shared.dump()
                // Append the Rust log too: whether easytier reached a relay and
                // whether it learned the peer's proxy CIDRs is only known over there,
                // and that is exactly what the routing question hinges on.
                if let path = rustLogPath,
                   let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    let tail = content.split(separator: "\n").suffix(400).joined(separator: "\n")
                    text += "\n\n===== rust log, last 400 lines @ \(path) =====\n\(tail)"
                } else {
                    text += "\n\n===== rust log unavailable (path=\(rustLogPath ?? "nil")) ====="
                }
                completionHandler(text.data(using: .utf8))
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
