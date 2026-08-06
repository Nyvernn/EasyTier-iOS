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
    /// Kept small deliberately. The whole buffer goes out in one provider message reply and
    /// an oversized reply comes back as nil rather than as an error, so the cap is set well
    /// under any plausible limit -- roughly 40 KB at the length these lines run. The
    /// interesting part of a startup problem is always the first minute, which fits several
    /// times over.
    private let limit = 400
    private var startedAt = Date()

    func append(_ message: String) {
        lock.lock()
        let elapsed = String(format: "%8.2f", Date().timeIntervalSince(startedAt))
        lines.append("[\(elapsed)] \(message)")
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        lock.unlock()
    }

    /// Emptied at the top of every tunnel session, because this process outlives the sessions
    /// it serves. Without this the replay of a second session would re-send the first one --
    /// the same startup twice, and the elapsed times counted from a process start that could
    /// be hours back, which reads as if the tunnel had taken hours to come up.
    func reset() {
        lock.lock()
        lines.removeAll()
        startedAt = Date()
        lock.unlock()
    }

    /// The build and the resolved App Group lead every dump rather than appearing as one
    /// timed line among hundreds: a wrong group silently disables the log file, the shared
    /// defaults and the widget all at once while leaving the tunnel up, so it has to be
    /// visible no matter how early the run went wrong.
    func dump() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return "diag build: \(DIAG_BUILD)\n"
            + "app group: \(APP_GROUP_ID) (\(APP_GROUP_SOURCE))\n"
            + snapshot.joined(separator: "\n")
    }
}

/// Log to OSLog and to the retrievable buffer at once.
///
/// `.warning` because OSLog drops `.info` and `.debug` without persisting them, so
/// anything below that would be gone by the time a properly signed build exports it.
func dlog(_ message: String) {
    logger.warning("\(message, privacy: .public)")
    DiagnosticsLog.shared.append(message)
    // Straight out over the tunnel as well, so nobody has to export anything by hand.
    // Best effort and never throws: a line that cannot leave is still in the buffer above.
    PacketTunnelProvider.emitTelemetry(message)
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
        // appMsgs rides along here because this line is the one that reliably arrives. Whether
        // a provider message ever reaches this process is the open question behind the blank
        // dashboard, and asking it through the per-message logging made the answer depend on
        // the same delivery that was failing. A zero here means they never arrive at all.
        let line = String(
            format: "memProbe(%@) t=%lds footprint=%.2fMiB peak=%.2fMiB resident=%.2fMiB pctOf50MiB=%.1f%% appMsgs=%ld",
            tag,
            elapsed,
            Double(sample.footprint) / mib,
            Double(memoryPeakBytes) / mib,
            Double(sample.resident) / mib,
            Double(sample.footprint) / (50.0 * mib) * 100.0,
            appMessageCounts.values.reduce(0, +)
        )
        // dlog alone: it now both buffers the line and puts it on the wire, so calling
        // sendTelemetry here as well would send every sample twice.
        dlog(line)
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
    // Opt-in, and deliberately so. The kernel scopes every socket this process opens to
    // the physical interface rather than to the tunnel this same process provides, so an
    // overlay-only target cannot be reached from here at all: the run would be 192 sockets
    // failing to connect, which measures nothing and spends three minutes of footprint
    // budget doing it. Set StressTarget ("host:port") in the App Group defaults to a
    // service reachable on the *physical* network -- the concurrency-to-memory curve is
    // about buffer counts, so it does not care which interface carries the bytes.
    //
    // The run stops by itself after the last stage, and sampling then continues at the
    // idle interval.
    private static let stressStages: [Int] = [8, 32, 96, 192]
    private static let stressStageSeconds: TimeInterval = 40
    private static let stressStartDelaySeconds: TimeInterval = 45
    private static let stressPayload = Data(count: 4096)

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
        guard let raw = UserDefaults(suiteName: APP_GROUP_ID)?.string(forKey: "StressTarget") else {
            return nil
        }
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
                dlog("stress skipped: no valid StressTarget host:port in App Group defaults"
                    + " (appGroup=\(APP_GROUP_ID) source=\(APP_GROUP_SOURCE))")
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
            // dlog already puts this on the wire; a second send would duplicate it.
            dlog(line)
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
        // No upload here: it runs on URLSession, which cannot be pinned to the tunnel, so
        // the request could not reach the sink. logMemory above already streamed the final
        // sample out as telemetry, which is what the curve is made of anyway.
        logger.warning("stress finished, returning to idle sampling")
    }

    // MARK: - Reachability preflight (NOT STARTED -- see startTunnel)
    //
    // The reason it is not started is the one fact worth keeping from this whole exercise:
    // the kernel automatically scopes sockets opened by a Network Extension process to the
    // physical interface, excluding them from the tunnel that same process provides. It is
    // a whole-process policy, so it applies no matter which API opens the socket. Three of
    // the four targets below are therefore unreachable from here, and their failure would
    // say nothing about whether the overlay route works -- a misreading that already cost
    // one round of diagnosis. Pinning a socket to the tunnel needs the provider's
    // `virtualInterface` (iOS 18+); this comes back when the probes do that, ideally
    // probing each target twice, pinned and unpinned, so the two causes separate.
    //
    //   overlay   the peer's virtual IP, port 11010 -- EasyTier's own listener. Only
    //             reachable through the tun device, so expected to fail here.
    //   proxied   the address behind the peer's --proxy-networks, likewise.
    //   logsink   the same proxied address, at the port the diagnostics upload posts to.
    //   internet  outside the tunnel entirely, so this one is expected to succeed. If it
    //             does not, the probe itself is broken and the rest prove nothing.
    //
    // Repeated a few times because the physical path itself changes (WiFi association,
    // captive portals), and the interface name logged with each result is what tells the
    // three failures above apart from a probe that never had a network to begin with.
    private static let preflightTargets: [(label: String, host: String, port: UInt16)] = [
        ("overlay", "10.144.144.1", 11010),
        ("proxied", "192.168.65.254", 8899),
        ("logsink", "192.168.65.254", 8898),
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
                // The interface is the point: it shows which path the socket was actually
                // placed on, so a failure caused by being scoped away from the tunnel is
                // distinguishable from one caused by the destination being down.
                let iface = conn.currentPath?.availableInterfaces
                    .map { $0.name }
                    .joined(separator: ",") ?? "none"
                dlog("\(name) -> \(outcome) iface=\(iface)")
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

    // MARK: - Diagnostics upload (NOT STARTED -- see startTunnel)
    //
    // POST the whole buffer to a listener on the peer, which cannot work as written for
    // the reason given above: URLSession from inside an .appex is scoped to the physical
    // interface like every other socket here, and the sink sits behind the peer's proxied
    // subnet. URLSession is also the one API with no way to be pinned to the tunnel -- the
    // documented answer is to have the container app issue the request instead.
    //
    // Kept because a timed upload is the only channel that survives a jetsam kill, which
    // is the failure this build most needs to catch. It returns either aimed at a host on
    // the physical network, or moved into the container app.
    private static let uploadHost = "192.168.65.254"
    private static let uploadPort = 8898
    private static let uploadFirstDelaySeconds: TimeInterval = 70
    private static let uploadIntervalSeconds: TimeInterval = 60
    private static let uploadTimeoutSeconds: TimeInterval = 20
    private var uploadSequence = 0
    private var uploadTimer: DispatchSourceTimer?

    /// A short label distinguishing one run's uploads from the next, since the sink
    /// names files by arrival time and a reconnect would otherwise interleave with the
    /// run before it. The overlay address goes in because the last diagnosis was derailed
    /// by two nodes silently claiming the same virtual IP, and dots become dashes so the
    /// tag stays one path segment.
    private lazy var uploadRunTag: String = {
        let vip = lastOptions.flatMap { $0.ipv4 }?
            .replacingOccurrences(of: ".", with: "-")
        let suffix = String(UInt32.random(in: 0..<0xFFFF), radix: 16)
        return "\(vip ?? "novip")-\(suffix)"
    }()

    private func startDiagnosticsUpload() {
        let timer = DispatchSource.makeTimerSource(queue: settingsQueue)
        timer.schedule(
            deadline: .now() + PacketTunnelProvider.uploadFirstDelaySeconds,
            repeating: PacketTunnelProvider.uploadIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.uploadDiagnostics(reason: "timer")
        }
        uploadTimer = timer
        timer.resume()
        dlog("startDiagnosticsUpload() sink=http://\(PacketTunnelProvider.uploadHost):\(PacketTunnelProvider.uploadPort) first=\(PacketTunnelProvider.uploadFirstDelaySeconds)s every=\(PacketTunnelProvider.uploadIntervalSeconds)s tag=\(uploadRunTag)")
    }

    private func stopDiagnosticsUpload() {
        uploadTimer?.cancel()
        uploadTimer = nil
    }

    private func uploadDiagnostics(reason: String) {
        uploadSequence += 1
        let seq = uploadSequence
        let tag = "\(uploadRunTag)-\(String(format: "%03d", seq))-\(reason)"
        guard let url = URL(
            string: "http://\(PacketTunnelProvider.uploadHost):\(PacketTunnelProvider.uploadPort)/\(tag)"
        ) else { return }

        // Snapshot before the request so the body cannot grow underneath it, and so the
        // line recording this attempt lands in the *next* upload rather than in this one.
        let body = Data(DiagnosticsLog.shared.dump().utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = PacketTunnelProvider.uploadTimeoutSeconds

        // Ephemeral: nothing about this should touch the extension's disk or cookie
        // storage, and a cache here would only distort the footprint being measured.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = PacketTunnelProvider.uploadTimeoutSeconds
        let session = URLSession(configuration: config)
        let started = Date()
        let task = session.dataTask(with: request) { _, response, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            if let error {
                dlog("upload[\(seq)] \(reason) FAILED after \(elapsed)s bytes=\(body.count): \(error)")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("upload[\(seq)] \(reason) ok status=\(code) bytes=\(body.count) in \(elapsed)s")
            }
            session.finishTasksAndInvalidate()
        }
        task.resume()
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

    // MARK: - Telemetry
    //
    // Every dlog line leaves the device as it is written, one UDP datagram each, so that
    // diagnosis stops depending on somebody exporting a file by hand.
    //
    // The target is the peer's proxied address rather than its overlay address, and not by
    // preference: the peer runs EasyTier inside a container, so the overlay address belongs
    // to that container's network namespace and nothing there listens, while the sink runs
    // on the host the container reaches at this address. Which means delivery doubles as
    // the measurement we actually want -- datagrams arriving proves the iPhone reaches the
    // proxied subnet, and the connection sitting in `waiting(No route to host)` says the
    // route for it was never installed.
    //
    // UDP because it is stateless: losing a datagram costs nothing, and there is no
    // reconnect logic to maintain in a process this memory-constrained.
    //
    // Overridable through TelemetryTarget ("host:port") in the App Group defaults, which
    // is reachable again now that the group resolves at runtime.
    private static let telemetryDefaultTarget = "192.168.65.254:8897"
    private var telemetryConnection: NWConnection?
    private var telemetryErrorCount = 0
    /// How many times the startup backlog has gone out on this connection.
    private var telemetryReplayCount = 0
    /// When to try again after `.ready`, which on its own has never delivered one.
    ///
    /// Measured: nothing written in roughly the first three seconds of a session ever reaches
    /// the sink, and everything after does -- the first proof of flow is a tail line at six
    /// seconds. `.ready` arrives inside that window, so replaying on it puts the entire
    /// startup block, which exists nowhere else, into the one interval that discards it. The
    /// fix is not a better signal but a later one.
    private static let telemetryReplayRetries: [TimeInterval] = [10, 25]

    private static func parseHostPort(_ raw: String) -> (host: String, port: UInt16)? {
        guard let separator = raw.lastIndex(of: ":") else { return nil }
        let host = String(raw[raw.startIndex..<separator])
        guard !host.isEmpty, let port = UInt16(raw[raw.index(after: separator)...]) else {
            return nil
        }
        return (host, port)
    }

    /// Scope a connection to the tunnel this provider itself supplies.
    ///
    /// Without this the kernel puts the socket on the physical interface -- it excludes an
    /// extension's own sockets from that extension's tunnel, as a whole-process policy --
    /// and an overlay address simply does not exist there. `virtualInterface` is the
    /// documented way back in and is non-nil by the time startTunnel runs.
    ///
    /// Silent by design: the caller is reached from dlog, so logging here would recurse.
    /// Whether pinning is possible at all is reported once, from startTunnel.
    private func pinToTunnel(_ parameters: NWParameters) {
        if #available(iOS 18.0, macOS 15.0, *) {
            parameters.requiredInterface = virtualInterface
        }
    }

    /// Bridge for `dlog`, which is a free function and has no provider to hand.
    ///
    /// Hops to `settingsQueue` because dlog is called from every queue in this process
    /// while `telemetryConnection` is not synchronised; the hop also keeps the datagrams
    /// in the order the lines were written.
    static func emitTelemetry(_ line: String) {
        guard let provider = current else { return }
        provider.settingsQueue.async { provider.sendTelemetry(line) }
    }

    /// Armed from startTunnel once the tunnel has its addresses and routes, rather than
    /// lazily on the first line.
    ///
    /// The timing is the whole point, but not in the way it first appears. Pinned to a tun
    /// device with no route to the target yet, a datagram is simply dropped and UDP does not
    /// buffer -- and that window turned out to last seconds, not milliseconds, and to outlast
    /// `.ready`. So opening late is necessary and still not sufficient: what actually gets the
    /// startup out is retrying the replay past the window, from the timers set up below.
    private func startTelemetry() {
        // A new connection per session, never a surviving one: this process outlives a tunnel
        // session, because iOS restarts the tunnel on a network change without calling
        // stopTunnel, and a carried-over connection is pinned to a utun that is gone. Worth
        // doing on its own -- though it was not, as once claimed here, the reason the startup
        // replay went missing. That was the dead window above, and only the retries fixed it.
        closeTelemetry()
        // Nothing is opened when it is switched off, so `sendTelemetry` finds no connection
        // and every line stops at the in-process buffer. One check, one place.
        guard isTelemetryEnabled() else {
            dlog("telemetry off (\(TELEMETRY_ENABLED_KEY) is false in the App Group defaults)")
            return
        }
        let raw = UserDefaults(suiteName: APP_GROUP_ID)?.string(forKey: "TelemetryTarget")
            ?? PacketTunnelProvider.telemetryDefaultTarget
        guard let target = PacketTunnelProvider.parseHostPort(raw),
              let port = NWEndpoint.Port(rawValue: target.port) else {
            dlog("telemetry disabled: \(raw) is not a valid host:port")
            return
        }
        let parameters = NWParameters.udp
        pinToTunnel(parameters)
        let conn = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(target.host), port: port),
            using: parameters
        )
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let line = "telemetry conn state: \(state)"
            DiagnosticsLog.shared.append(line)
            // Put on the wire as well, not only in the buffer. Which states this connection
            // reaches is the first thing to know when lines go missing, and recording it only
            // in the buffer made that fact depend on the very replay that was failing.
            self.transmit(line, over: conn)
            if case .ready = state {
                self.replayBufferedTelemetry(trigger: "ready")
            }
        }
        conn.start(queue: settingsQueue)
        telemetryConnection = conn
        // Into the buffer rather than through dlog, so the replay carries it once instead
        // of the replay and the live path each carrying a copy.
        DiagnosticsLog.shared.append("telemetry opened to \(target.host):\(target.port)")
        for delay in PacketTunnelProvider.telemetryReplayRetries {
            settingsQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.replayBufferedTelemetry(trigger: "+\(Int(delay))s")
            }
        }
    }

    /// Sends everything logged before the wire existed, once, on the first `.ready`.
    ///
    /// Guarded against running twice because a UDP connection can report `.ready` again
    /// after a path change, and a second replay would duplicate the whole startup. Takes the
    /// connection from the property rather than as an argument, so the state handler that
    /// calls it does not have to capture the connection it is attached to.
    private func replayBufferedTelemetry(trigger: String) {
        guard let conn = telemetryConnection else { return }
        telemetryReplayCount += 1
        let pass = telemetryReplayCount
        let lines = DiagnosticsLog.shared.dump().split(
            separator: "\n", omittingEmptySubsequences: false
        )
        for line in lines {
            transmit(String(line), over: conn)
        }
        // Last, and names its own pass and count, so a reader can tell which attempt got
        // through and how much of the startup existed by then. A pass that arrives duplicating
        // an earlier one costs a dozen datagrams; a startup nobody can see costs a build.
        transmit("telemetry replay pass \(pass) via \(trigger): \(lines.count) lines", over: conn)
    }

    /// Never calls `dlog`, at any depth: it is called *from* dlog, so that would recurse
    /// until the stack ran out. Its own failures go straight to the buffer instead.
    private func sendTelemetry(_ line: String) {
        guard let conn = telemetryConnection else { return }
        transmit(line, over: conn)
    }

    private func transmit(_ line: String, over conn: NWConnection) {
        // Truncated to stay inside the tunnel's MTU. A datagram larger than that is
        // fragmented or dropped outright, and a route dump is the one line long enough to
        // reach it -- losing its tail beats losing the line.
        let capped = line.count > 900 ? String(line.prefix(900)) + "…[cut]" : line
        guard let data = (capped + "\n").data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            // Only the first few: the failure mode is identical every time, and one entry
            // per line would bury everything else in the buffer.
            guard self.telemetryErrorCount < 3 else { return }
            self.telemetryErrorCount += 1
            DiagnosticsLog.shared.append(
                "telemetry send failed (#\(self.telemetryErrorCount)): \(error)"
            )
        })
    }

    // MARK: - Rust log streaming
    //
    // The core writes far more than the Swift side ever will -- which peer answered, which
    // route arrived, why a connection failed -- and none of it passes through dlog, so none
    // of it reached the sink. That gap is the only reason diagnosis kept ending in "send me
    // the log file".
    //
    // Read incrementally from a remembered offset, a bounded slice per tick. An earlier
    // attempt loaded the whole file to take a tail of it, which in a process capped near
    // 46 MiB against a log that reaches megabytes in minutes was fatal on its own.
    private static let rustLogTailInterval: TimeInterval = 5
    /// Read in slices this size so peak memory stays flat however far behind the tail is.
    private static let rustLogTailChunk = 64 * 1024
    /// How much may be *read* per tick, across as many slices as that takes. Far above what
    /// is sent, and deliberately so: the core writes around 23 KB/s, and reading at the rate
    /// it is sent left the tail permanently behind -- skipping a quarter of a megabyte every
    /// tick, indiscriminately, so the lines that survived were an arbitrary 5% rather than
    /// the interesting ones. What costs anything here is the wire, and the filter below is
    /// what keeps that small; reading is cheap and is what decides the filter ever sees a
    /// line at all.
    private static let rustLogTailBudget = 512 * 1024
    /// Past this far behind, skip forward rather than stay behind forever: a permanent lag
    /// means everything arriving is stale, which is worse than a gap that says so.
    private static let rustLogTailMaxBacklog = 2 * 1024 * 1024
    /// One line per forwarded packet, and 96% of everything the tail produced in its first
    /// run: 16552 lines out of 17312. Left in, it buries every other line in the stream and
    /// adds steady traffic to a link whose memory leak scales with exactly that. Matched as a
    /// substring because the message is fixed and the peer ids after it are not.
    private static let rustLogNoise = ["foreign network client send msg success"]
    private var rustLogTailTimer: DispatchSourceTimer?
    private var rustLogTailHandle: FileHandle?
    private var rustLogTailOffset: UInt64 = 0
    private var rustLogSuppressed = 0

    private func startRustLogTail() {
        // Reopened per session for the same reason the telemetry connection is: the core
        // reopens its log in initRustLogger, so a handle carried over from the previous
        // session can be holding a file nobody writes to any more.
        stopRustLogTail()
        guard isTelemetryEnabled() else { return }
        guard let path = rustLogPath, let handle = FileHandle(forReadingAtPath: path) else {
            dlog("rust log tail: cannot open \(rustLogPath ?? "nil")")
            return
        }
        rustLogTailHandle = handle
        // From the current end. What came before is already covered by the buffer replay,
        // and re-sending a file that may be large is the thing being avoided here.
        rustLogTailOffset = (try? handle.seekToEnd()) ?? 0
        let timer = DispatchSource.makeTimerSource(queue: settingsQueue)
        timer.schedule(
            deadline: .now() + PacketTunnelProvider.rustLogTailInterval,
            repeating: PacketTunnelProvider.rustLogTailInterval
        )
        timer.setEventHandler { [weak self] in self?.pumpRustLogTail() }
        timer.resume()
        rustLogTailTimer = timer
        dlog("rust log tail started at offset \(rustLogTailOffset) of \(path)")
    }

    private func stopRustLogTail() {
        rustLogTailTimer?.cancel()
        rustLogTailTimer = nil
        try? rustLogTailHandle?.close()
        rustLogTailHandle = nil
        rustLogTailOffset = 0
        rustLogSuppressed = 0
    }

    private func pumpRustLogTail() {
        guard let handle = rustLogTailHandle, let conn = telemetryConnection else { return }
        do {
            let end = try handle.seekToEnd()
            // The appender truncates when the log is cleared, so a file shorter than last
            // time means the offset points past data that no longer exists.
            if end < rustLogTailOffset { rustLogTailOffset = 0 }
            guard end > rustLogTailOffset else { return }
            if end - rustLogTailOffset > UInt64(PacketTunnelProvider.rustLogTailMaxBacklog) {
                // Forward to within one tick's reading, so the catching up finishes on this
                // tick rather than trailing the truth for however long the backlog lasts.
                let keep = UInt64(PacketTunnelProvider.rustLogTailBudget)
                let skipped = end - rustLogTailOffset - keep
                rustLogTailOffset = end - keep
                dlog("rust log tail fell behind, skipped \(skipped) bytes")
            }
            var budget = PacketTunnelProvider.rustLogTailBudget
            var suppressed = 0
            while budget > 0, rustLogTailOffset < end {
                let start = rustLogTailOffset
                try handle.seek(toOffset: start)
                let want = Int(min(
                    min(end - start, UInt64(PacketTunnelProvider.rustLogTailChunk)),
                    UInt64(budget)
                ))
                guard let raw = try handle.read(upToCount: want), !raw.isEmpty else { break }
                // Re-wrapped so the indices start at zero: Data subsequences keep the parent's,
                // and the newline search below would otherwise be off by that offset.
                let chunk = Data(raw)
                budget -= chunk.count
                let usable: Data
                if let lastBreak = chunk.lastIndex(of: 0x0A) {
                    // Only up to the last newline, so a line is never split across two
                    // datagrams; the remainder is picked up on the next pass.
                    usable = chunk.prefix(upTo: lastBreak)
                    rustLogTailOffset = start + UInt64(lastBreak) + 1
                } else {
                    // A slice with no newline in it at all means one line longer than the
                    // slice. Consume it anyway: returning here would re-read the same bytes
                    // every tick and the tail would never move again.
                    usable = chunk
                    rustLogTailOffset = start + UInt64(chunk.count)
                }
                for rawLine in String(decoding: usable, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(rawLine)
                    if PacketTunnelProvider.rustLogNoise.contains(
                        where: { line.range(of: $0) != nil }
                    ) {
                        suppressed += 1
                        continue
                    }
                    transmit("RUST " + line, over: conn)
                }
            }
            // Said out loud rather than dropped quietly: a filtered stream that does not
            // admit to filtering reads as the whole log, and the count is also the cheapest
            // measure of how much the tunnel is actually forwarding.
            if suppressed > 0 {
                rustLogSuppressed += suppressed
                transmit("RUST-FILTER suppressed \(rustLogSuppressed) noise lines so far", over: conn)
            }
        } catch {
            dlog("rust log tail read failed: \(error)")
            stopRustLogTail()
        }
    }

    private func closeTelemetry() {
        telemetryConnection?.cancel()
        telemetryConnection = nil
        // Reset so the next tunnel session replays its own startup rather than
        // starting mid-story.
        telemetryReplayCount = 0
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

    // MARK: - Running info published to the App Group
    //
    // Written on a timer rather than answered on request. The dashboard asked over
    // sendProviderMessage and got nil every time, while the identical call works in here --
    // the routes it installs are built from it. Two things could explain that nil: the message
    // never arrives, or the reply is past whatever size that channel carries (a 40 KB one came
    // back nil earlier in this work). Publishing does not depend on knowing which, and if the
    // messages never arrive then answering on request could not work by definition.
    //
    // On a timer and not from the core's changed-callback because that fires on peer and route
    // changes, and a dashboard also shows counters that move without either.
    private static let runningInfoInterval: TimeInterval = 2
    private var runningInfoTimer: DispatchSourceTimer?
    private var runningInfoWrites = 0
    private var runningInfoFailure: String?

    private func startRunningInfoPublisher() {
        stopRunningInfoPublisher()
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APP_GROUP_ID
        ) else {
            dlog("running info publisher: no App Group container for \(APP_GROUP_ID)")
            return
        }
        let url = container.appendingPathComponent(RUNNING_INFO_FILENAME)
        let timer = DispatchSource.makeTimerSource(queue: settingsQueue)
        timer.schedule(
            deadline: .now(),
            repeating: PacketTunnelProvider.runningInfoInterval
        )
        timer.setEventHandler { [weak self] in self?.publishRunningInfo(to: url) }
        timer.resume()
        runningInfoTimer = timer
        dlog("running info publisher every \(PacketTunnelProvider.runningInfoInterval)s to \(url.path)")
    }

    private func stopRunningInfoPublisher() {
        runningInfoTimer?.cancel()
        runningInfoTimer = nil
        runningInfoWrites = 0
        runningInfoFailure = nil
    }

    private func publishRunningInfo(to url: URL) {
        var infoPtr: UnsafePointer<CChar>? = nil
        var errPtr: UnsafePointer<CChar>? = nil
        guard get_running_info(&infoPtr, &errPtr) == 0,
              let info = extractRustString(infoPtr),
              let data = info.data(using: .utf8) else {
            noteRunningInfoFailure(extractRustString(errPtr) ?? "get_running_info gave nothing")
            return
        }
        do {
            // Atomic, because the app reads this file on its own schedule and a partial read
            // would look like corrupt data rather than a timing problem.
            try data.write(to: url, options: .atomic)
            runningInfoWrites += 1
            // The first write, then sparsely: what is worth knowing is that it started and
            // that it is still going, not each of the thousands in between.
            if runningInfoWrites == 1 || runningInfoWrites % 150 == 0 {
                dlog("running info published #\(runningInfoWrites), \(data.count) bytes")
            }
        } catch {
            noteRunningInfoFailure("write failed: \(error.localizedDescription)")
        }
    }

    /// Only when the reason changes, since this runs every couple of seconds and a permanent
    /// failure would otherwise say the same thing until the buffer held nothing else.
    private func noteRunningInfoFailure(_ reason: String) {
        guard runningInfoFailure != reason else { return }
        runningInfoFailure = reason
        dlog("running info publish failed: \(reason)")
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
            // Ahead of the first dlog below, so the buffer this session's replay sends holds
            // this session and nothing else.
            DiagnosticsLog.shared.reset()

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
                    // Whether telemetry can leave at all hinges on this, and it is the
                    // first thing to check when nothing arrives at the sink. Logged once
                    // here rather than per connection, because the pinning helper is
                    // reached from dlog and cannot log without recursing.
                    if #available(iOS 18.0, macOS 15.0, *) {
                        dlog("tunnel pinning via virtualInterface="
                            + (self.virtualInterface?.name ?? "NIL -- nothing can be pinned"))
                    } else {
                        dlog("tunnel pinning UNAVAILABLE: virtualInterface needs iOS 18, so"
                            + " telemetry goes out the physical interface and cannot reach"
                            + " an overlay address")
                    }
                    self.startTelemetry()
                    self.startRustLogTail()
                    self.startMemoryProbe()
                    self.startRunningInfoPublisher()
                    // startDiagnosticsUpload() stays off: it is built on URLSession, which
                    // is the one API with no way to be pinned to the tunnel, so it cannot
                    // reach an overlay address from here however it is configured. The
                    // per-line telemetry above replaces it. schedulePreflight() stays off
                    // until its probes are pinned too -- unpinned, their failures say
                    // nothing about routing and only mislead.
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
            self.stopDiagnosticsUpload()
            self.stopRustLogTail()
            self.stopRunningInfoPublisher()
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
    
    /// Writes the buffer into the shared container and reports its path, rather than
    /// returning the text in the reply itself.
    ///
    /// The text does not fit. Roughly 40 KB came back to the app as nil, and the channel's
    /// limit is undocumented, so there is no size to design against -- only a ceiling to
    /// stop relying on. Handing back a path is what exportOSLog already does, it has no
    /// such ceiling, and the container is reachable now that the App Group resolves at
    /// runtime. When it is not reachable, the reason says so, because that reason is
    /// itself the diagnosis.
    private func diagnosticsResponse() -> ProviderMessageResponse {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) else {
            return .init(
                ok: false,
                path: nil,
                error: "App Group container unavailable"
                    + " (id=\(APP_GROUP_ID) source=\(APP_GROUP_SOURCE))"
            )
        }
        // A separate file from LOG_FILENAME on purpose: that one belongs to the Rust
        // tracing appender, which may rotate or truncate it underneath a second writer.
        let url = container.appendingPathComponent("easytier-diagnostics.txt")
        do {
            try Data(DiagnosticsLog.shared.dump().utf8).write(to: url, options: .atomic)
            return .init(ok: true, path: url.path, error: nil)
        } catch {
            return .init(ok: false, path: nil, error: "write failed: \(error)")
        }
    }

    /// How many times each command has been seen, so the 1 Hz runningInfo poll cannot
    /// drown the log. Touched only on `settingsQueue`.
    private var appMessageCounts: [String: Int] = [:]

    /// Records what arrived and how big the answer was.
    ///
    /// Worth the noise because a blank dashboard has two indistinguishable causes: the
    /// command never reached this process, or it did and the reply was too large for the
    /// channel to carry. Only the reply size tells those apart, and only from this side.
    private func logAppMessage(_ raw: String, replyBytes: Int?) {
        settingsQueue.async { [weak self] in
            guard let self else { return }
            let seen = (self.appMessageCounts[raw] ?? 0) + 1
            self.appMessageCounts[raw] = seen
            // The first few answer the question; after that one in sixty is enough to show
            // it is still alive without filling the buffer with a line per second.
            guard seen <= 3 || seen % 60 == 0 else { return }
            let size = replyBytes.map { "\($0) bytes" } ?? "NIL"
            dlog("handleAppMessage(\(raw)) #\(seen) reply=\(size)")
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        logger.debug("handleAppMessage(): triggered")
        guard let completionHandler else {
            logAppMessage(
                String(data: messageData, encoding: .utf8) ?? "<non-utf8>",
                replyBytes: nil
            )
            return
        }
        let raw = String(data: messageData, encoding: .utf8)
        // Every answer goes through here, so there is one place that knows what was sent
        // back -- including the paths that answer nil.
        let reply: (Data?) -> Void = { [weak self] data in
            self?.logAppMessage(raw ?? "<non-utf8 \(messageData.count) bytes>", replyBytes: data?.count)
            completionHandler(data)
        }
        if let raw, let command = ProviderCommand(rawValue: raw) {
            switch command {
            case .clearLog:
                var errPtr: UnsafePointer<CChar>? = nil
                if clear_logger(&errPtr) == 0 {
                    let response = ProviderMessageResponse(ok: true, path: nil, error: nil)
                    let data = try? JSONEncoder().encode(response)
                    reply(data)
                } else {
                    let err = extractRustString(errPtr) ?? "Unknown"
                    logger.error("handleAppMessage() clear logger failed: \(err, privacy: .public)")
                    let response = ProviderMessageResponse(ok: false, path: nil, error: err)
                    let data = try? JSONEncoder().encode(response)
                    reply(data)
                }
            case .exportOSLog:
                do {
                    let url = try OSLogExporter.exportToAppGroup(appGroupID: APP_GROUP_ID)
                    let response = ProviderMessageResponse(ok: true, path: url.path, error: nil)
                    let data = try JSONEncoder().encode(response)
                    reply(data)
                } catch {
                    let response = ProviderMessageResponse(ok: false, path: nil, error: error.localizedDescription)
                    let data = try? JSONEncoder().encode(response)
                    reply(data)
                }
            case .runningInfo:
                var infoPtr: UnsafePointer<CChar>? = nil
                var errPtr: UnsafePointer<CChar>? = nil
                if get_running_info(&infoPtr, &errPtr) == 0, let info = extractRustString(infoPtr) {
                    reply(info.data(using: .utf8))
                } else if let err = extractRustString(errPtr) {
                    logger.error("handleAppMessage() failed: \(err, privacy: .public)")
                    reply(nil)
                } else {
                    reply(nil)
                }
            case .diagnostics:
                reply(try? JSONEncoder().encode(diagnosticsResponse()))
            case .lastNetworkSettings:
                settingsQueue.async { [weak self] in
                    guard let lastAppliedSettings = self?.lastAppliedSettings else {
                        reply(nil)
                        return
                    }
                    do {
                        let data = try JSONEncoder().encode(lastAppliedSettings)
                        reply(data)
                    } catch {
                        logger.error("handleAppMessage() encode settings failed: \(error, privacy: .public)")
                        reply(nil)
                    }
                }
            }
            return
        }
        reply(nil)
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
