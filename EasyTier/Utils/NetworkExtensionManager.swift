import Foundation
import Combine
// Explicit: NWConnection is used directly by AppTelemetry below, and this target builds
// with MEMBER_IMPORT_VISIBILITY on, so it is not inherited through NetworkExtension.
import Network
import NetworkExtension
import WidgetKit
import os
#if os(iOS)
import UIKit
#else
import SystemConfiguration
#endif

import EasyTierShared
import TOMLKit

/// Sends diagnostic lines from the *app* to the same sink the tunnel extension reports to.
///
/// The app needs a path of its own because the failures worth seeing happen here: the
/// extension hands back a status document and it is this process that fails to decode it,
/// so the extension's log cannot say what went wrong. And it can have one, unlike the
/// extension -- an ordinary app's sockets are not scoped away from the tunnel the way a
/// Network Extension's are, so a datagram to the peer's proxied address just goes through
/// it. Which also means this only works while the tunnel is up, and that is precisely when
/// there is anything to report.
///
/// Lines are held until the connection reports `.ready`, and this is the whole design.
/// A datagram handed over before then is discarded by the stack, and the caller reports each
/// distinct outcome exactly once -- so the one datagram that mattered would be the one lost,
/// every time, and the sink would stay empty while looking like a delivery problem.
///
/// Fire and forget past that point: no route, no sink, and a datagram simply vanishes with
/// no consequence to the caller.
final class AppTelemetry {
    static let shared = AppTelemetry()

    private static let target = NWEndpoint.hostPort(host: "192.168.65.254", port: 8897)
    /// Bounded, because the tunnel may never come up and this must not grow without limit.
    /// The oldest go first: a stale outcome is worth less than the current one.
    private static let backlogLimit = 200

    /// Retried rather than abandoned, because `sendOnce` gives each line one chance: nothing
    /// re-triggers a line whose connection was not up when it was written. Bounded so an
    /// unreachable sink costs a fixed number of attempts instead of retrying for the session.
    private static let reopenDelay: TimeInterval = 3
    private static let reopenLimit = 10
    /// How many times the backlog is sent, and how far apart. The extension's telemetry
    /// measured the window from the other side: nothing sent in roughly the first three
    /// seconds of a tunnel session arrives, and the first proof of flow is at six. So the
    /// later rounds are the ones that matter and the first is nearly free.
    private static let flushRounds = 4
    private static let flushInterval: TimeInterval = 6

    private let queue = DispatchQueue(label: "\(APP_BUNDLE_ID).app.telemetry")
    private var connection: NWConnection?
    private var backlog: [String] = []
    private var lastByKey: [String: String] = [:]
    private var reopenCount = 0
    private var flushing = false

    /// Tagged APP so a reader can tell these apart from the extension's own lines in a log
    /// both processes write to.
    func send(_ line: String) {
        queue.async { [self] in enqueue(line) }
    }

    /// Sends only when `line` differs from the last one sent under `key`.
    ///
    /// The dedup lives here rather than in the caller because this queue is the only place
    /// that is already serialised. A poll running once a second, whose reply handler may be
    /// invoked on some other queue, would otherwise be racing on its own bookkeeping.
    func sendOnce(key: String, _ line: String) {
        queue.async { [self] in
            guard lastByKey[key] != line else { return }
            lastByKey[key] = line
            enqueue(line)
        }
    }

    private func enqueue(_ line: String) {
        // Checked here rather than at each call site: this is the one door every line comes
        // through, and reading it per line keeps the switch live without a reconnect.
        guard isTelemetryEnabled() else { return }
        backlog.append(line)
        if backlog.count > Self.backlogLimit {
            backlog.removeFirst(backlog.count - Self.backlogLimit)
        }
        if connection == nil { openConnection() }
        guard !flushing else { return }
        flushing = true
        flush(round: 1)
    }

    /// Everything below runs on `queue`, including the state handler, because the connection
    /// was started on it. So none of this needs further synchronisation.
    private func openConnection() {
        let conn = NWConnection(to: Self.target, using: .udp)
        // Both weak, and checked against the current connection: a cancelled connection keeps
        // reporting for a while after being let go of, and without the identity check that
        // late `.cancelled` would tear down whichever connection had replaced it in the
        // meantime -- once per reopen, forever. Weak on `conn` also keeps the connection from
        // retaining the handler that holds it.
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                self.reopenCount = 0
            case .waiting, .failed, .cancelled:
                // All three end the same way: let go of this one and open another shortly,
                // by which time the tunnel may exist where it did not. `.waiting` is included
                // because the framework's own retry watches the physical path, and the path
                // this needs is a tunnel that comes up seconds later; a connection parked
                // there reports no failure, so nothing else would notice.
                self.reopen()
            default:
                break
            }
        }
        // Current before started, so the identity check above cannot reject the very first
        // state update this connection reports.
        connection = conn
        conn.start(queue: queue)
    }

    /// Dropped and retried rather than cancelled in place: cancelling is what makes the
    /// framework let go, and a fresh connection is what picks up a route that did not exist
    /// when the last one was opened.
    private func reopen() {
        guard let current = connection else { return }
        connection = nil
        current.cancel()
        guard !backlog.isEmpty, reopenCount < Self.reopenLimit else { return }
        reopenCount += 1
        queue.asyncAfter(deadline: .now() + Self.reopenDelay) { [self] in
            guard connection == nil, !backlog.isEmpty else { return }
            openConnection()
        }
    }

    /// Sends the whole backlog now, again on a timer a few times, then lets it go.
    ///
    /// Not gated on `.ready`. Measured from the extension side, readiness is announced while
    /// the tunnel still discards datagrams, so waiting for it and sending once is a reliable
    /// way to lose everything -- which is at least part of why no app-side line has ever
    /// arrived. Repeating a handful of lines over UDP costs nothing, and a duplicate in the log
    /// beats a silence that means two different things.
    private func flush(round: Int) {
        for line in backlog {
            guard let data = "APP \(line)\n".data(using: .utf8) else { continue }
            connection?.send(content: data, completion: .idempotent)
        }
        guard round < Self.flushRounds else {
            backlog.removeAll()
            flushing = false
            return
        }
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [self] in
            if connection == nil { openConnection() }
            flush(round: round + 1)
        }
    }
}

protocol NetworkExtensionManagerProtocol: ObservableObject {
    var status: NEVPNStatus { get }
    var connectedDate: Date? { get }
    var isLoading: Bool { get }
    var isAlwaysOnEnabled: Bool { get set }
    
    func load() async throws
    @MainActor
    func connect() async throws
    func disconnect() async
    func fetchRunningInfo(_ callback: @escaping ((NetworkStatus) -> Void))
    func fetchLastNetworkSettings(_ callback: @escaping ((TunnelNetworkSettingsSnapshot?) -> Void))
    func updateName(name: String, server: String) async
    func clearCoreLog() async throws
    func exportExtensionLogs() async throws -> URL
    func fetchDiagnostics() async throws -> URL
    @MainActor
    func setAlwaysOnEnabled(_ enabled: Bool) async throws
}

class NetworkExtensionManager: NetworkExtensionManagerProtocol {
    private static let logger = Logger(subsystem: APP_BUNDLE_ID, category: "NEManager")

    private struct ProviderMessageResponse: Codable {
        let ok: Bool
        let path: String?
        let error: String?
    }

    enum NEManagerError: LocalizedError {
        case providerUnavailable
        case invalidResponse
        case clearFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .providerUnavailable:
                return "provider unavailable"
            case .invalidResponse:
                return "invalid response"
            case .clearFailed(let message):
                return message
            case .exportFailed(let message):
                return message
            }
        }
    }

    private var manager: NETunnelProviderManager?
    private var connection: NEVPNConnection?
    private var observer: Any?

    @Published var status: NEVPNStatus
    @Published var connectedDate: Date?
    @Published var isLoading = true
    @Published var isAlwaysOnEnabled = false
    
    init() {
        status = .invalid
    }

    private func registerObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let manager = manager {
            observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NEVPNStatusDidChange,
                object: manager.connection,
                queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let connection = notification.object as? NEVPNConnection
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.connection = connection
                    self.status = self.connection?.status ?? .invalid
                    self.connectedDate = self.connection?.connectedDate
                    if self.status == .invalid {
                        self.manager = nil
                    }
                    if self.status == .connected {
                        // Tied to the tunnel coming up rather than to app launch, because
                        // before that there is no route to the sink at all. Its only job is to
                        // separate "the app cannot reach the sink" from "the dashboard never
                        // asks": without it, one silent log means both and neither.
                        AppTelemetry.shared.sendOnce(key: "app", "build=\(DIAG_BUILD)")
                    }
                    
                    // Sync VPN connection status to App Group for Control Widget
                    self.syncWidgetState()
                }
            }
        }
    }
    
    // Notify Control Widget to refresh its state
    private func syncWidgetState() {
        if #available(iOS 18.0, macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "\(APP_BUNDLE_ID).control")
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "\(APP_BUNDLE_ID).widget")
    }
    
    private func reset() {
        manager = nil
        connection = nil
        status = .invalid
        connectedDate = nil
        isAlwaysOnEnabled = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        isLoading = false
    }
    
    private func setManager(manager: NETunnelProviderManager?) {
        self.manager = manager
        connection = manager?.connection
        status = manager?.connection.status ?? .invalid
        connectedDate = manager?.connection.connectedDate
        isAlwaysOnEnabled = manager?.isOnDemandEnabled ?? false
        registerObserver()
    }
    
    static func install() async throws -> NETunnelProviderManager {
        Self.logger.info("install()")
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "EasyTier"
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = "\(APP_BUNDLE_ID).tunnel"
        tunnelProtocol.serverAddress = "localhost"
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            return manager
        } catch {
            Self.logger.error("install() failed: \(String(describing: error))")
            throw error
        }
    }

    func load() async throws {
        Self.logger.info("load()")
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first
            for m in managers {
                if m != manager {
                    try? await m.removeFromPreferences()
                    Self.logger.info("load() removed unnecessary profile")
                }
            }
            setManager(manager: manager)
            isLoading = false
        } catch {
            Self.logger.error("load() failed: \(String(describing: error))")
            reset()
            throw error
        }
    }
    
    static func generateOptions(_ profile: inout NetworkProfile) throws -> EasyTierOptions {
        try profile.prepareForUse()
        var options = EasyTierOptions()
        var config = profile.toConfig()
        if config.hostname == nil && UserDefaults.standard.bool(forKey: "useRealDeviceNameAsDefault") {
#if os(iOS)
            config.hostname = UIDevice.current.name
#else
            config.hostname = SCDynamicStoreCopyComputerName(nil, nil) as String?
#endif
        }

        let encoded: String
        do {
            encoded = try TOMLEncoder().encode(config).string ?? ""
        } catch {
            Self.logger.error("generateOptions() generate config failed: \(String(describing: error))")
            throw error
        }
        options.config = encoded
        if let ipv4 = config.ipv4 {
            options.ipv4 = ipv4
        }
        if let ipv6 = config.ipv6 {
            options.ipv6 = ipv6
        }
        if let mtu = config.flags?.mtu {
            options.mtu = mtu
        } else {
            options.mtu = config.flags?.enableEncryption ?? true ? 1360 : 1380
        }
        if let routes = config.routes {
            options.routes = routes
        }
        options.exitNodes = config.exitNodes
        if let logLevel = UserDefaults.standard.string(forKey: "logLevel"),
           let logLevel = LogLevel.init(rawValue: logLevel) {
            options.logLevel = logLevel
        }
        if profile.enableMagicDNS {
            options.magicDNS = true
        }
        if profile.enableOverrideDNS {
            options.dns = profile.overrideDNS.compactMap { $0.text.isEmpty ? nil : $0.text }
        }
        
        return options
    }
    
    // Mirror of the last encoded options, handed to the tunnel through
    // providerConfiguration on connect. The App Group route alone is not dependable:
    // re-signing the IPA with a third-party certificate voids the
    // group.cn.easytier entitlement, and then the extension cannot read VPNConfig at
    // all. providerConfiguration is persisted by the system with the VPN configuration
    // itself, so it survives that. Kept in memory only -- it is just a relay between
    // saveOptions() and the next connect() in the same process.
    nonisolated(unsafe) private static var lastOptionsData: Data?

    static func saveOptions(_ options: EasyTierOptions) {
        // Save config to App Group for Widget use
        let defaults = UserDefaults(suiteName: APP_GROUP_ID)
        if let configData = try? JSONEncoder().encode(options) {
            logger.debug("save options: \(configData.string ?? "nil")")
            defaults?.set(configData, forKey: "VPNConfig")
            defaults?.synchronize()
            lastOptionsData = configData
        }
    }
    
    func connect() async throws {
        guard ![.connecting, .connected, .disconnecting, .reasserting].contains(status) else {
            Self.logger.warning("connect() failed: in \(String(describing: self.status)) status")
            return
        }
        guard !isLoading else {
            Self.logger.warning("connect() failed: not loaded")
            return
        }
        if status == .invalid {
            _ = try await NetworkExtensionManager.install()
            try await load()
        }
        guard let manager else {
            Self.logger.error("connect() failed: manager is nil")
            return
        }

        // Give the tunnel a second way to read its configuration; see lastOptionsData.
        // connectWithManager() calls saveToPreferences() right after configuring the
        // manager, so this gets persisted along with everything else.
        if let optionsData = Self.lastOptionsData,
           let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
            tunnelProtocol.providerConfiguration = ["options": optionsData]
        }

        do {
            try await connectWithManager(manager, logger: Self.logger)
        } catch {
            Self.logger.error("connect() start vpn tunnel failed: \(String(describing: error))")
            throw error
        }
        Self.logger.info("connect() started")
        // Immediately sync widget state after initiating connection
        syncWidgetState()
    }
    
    func disconnect() async {
        guard let manager else {
            Self.logger.error("disconnect() failed: manager is nil")
            return
        }
        let connection = manager.connection
        guard [.connecting, .connected, .reasserting, .disconnecting].contains(connection.status) else {
            return
        }

        connection.stopVPNTunnel()
        // Immediately sync widget state after initiating disconnection
        syncWidgetState()

        while [.connecting, .connected, .reasserting, .disconnecting].contains(connection.status) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    
    func updateName(name: String, server: String) async {
        guard let manager else { return }
        manager.localizedDescription = name
        manager.protocolConfiguration?.serverAddress = server
        try? await manager.saveToPreferences()
    }
    
    // Every exit below reports its outcome. They all used to return quietly, which is why
    // a dashboard with nothing on it could not be told apart from a tunnel that had not
    // come up: the screen looks the same whether the reply never arrived, arrived and did
    // not decode, or was never asked for.
    /// Read from the shared container, where the extension publishes it every couple of
    /// seconds, rather than requested over `sendProviderMessage`.
    ///
    /// That request returned nil on every single poll, while the identical call inside the
    /// extension returns real data -- it is what the installed routes are built from. Either
    /// the message never arrived or the reply was past whatever size the channel carries; this
    /// works in both cases, and in the first no request-and-answer scheme could.
    func fetchRunningInfo(_ callback: @escaping ((NetworkStatus) -> Void)) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APP_GROUP_ID
        ) else {
            report("no App Group container for \(APP_GROUP_ID)")
            return
        }
        let url = container.appendingPathComponent(RUNNING_INFO_FILENAME)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Expected until the tunnel has been up for a second or two, and the message says
            // so rather than looking like a failure.
            report("no \(RUNNING_INFO_FILENAME) yet: \(error.localizedDescription)")
            return
        }
        let info: NetworkStatus
        do {
            info = try JSONDecoder().decode(NetworkStatus.self, from: data)
        } catch {
            // Verbatim: a DecodingError names the key it choked on, and one mismatched field
            // takes the whole document down with it.
            Self.logger.error("fetchRunningInfo() json deserialize failed: \(String(describing: error))")
            report("\(data.count) bytes did not decode: \(error)")
            return
        }
        // Rounded, so a payload that grows by a few bytes each second does not report itself
        // over and over.
        report("decoded ok from the App Group, about \(data.count / 1024) KiB")
        callback(info)
    }

    /// Reports a status-poll outcome, deduped: the poll runs once a second and the same
    /// outcome repeats indefinitely, so the transition is the whole message.
    private func report(_ outcome: String) {
        AppTelemetry.shared.sendOnce(key: "fetchRunningInfo", "fetchRunningInfo() \(outcome)")
    }

    func fetchLastNetworkSettings(_ callback: @escaping ((TunnelNetworkSettingsSnapshot?) -> Void)) {
        guard let manager else {
            callback(nil)
            return
        }
        guard let session = manager.connection as? NETunnelProviderSession,
              session.status != .invalid else {
            callback(nil)
            return
        }
        do {
            let message = ProviderCommand.lastNetworkSettings.rawValue.data(using: .utf8) ?? Data()
            try session.sendProviderMessage(message) { data in
                guard let data else {
                    callback(nil)
                    return
                }
                do {
                    let settings = try JSONDecoder().decode(TunnelNetworkSettingsSnapshot.self, from: data)
                    callback(settings)
                } catch {
                    Self.logger.error("fetchLastNetworkSettings() json deserialize failed: \(String(describing: error))")
                    callback(nil)
                }
            }
        } catch {
            Self.logger.error("fetchLastNetworkSettings() failed: \(String(describing: error))")
            callback(nil)
        }
    }

    /// Ask the extension to write a file into the shared container and hand back its path.
    ///
    /// Shared by the OSLog export and the diagnostics dump, which differ only in which file
    /// the extension writes. Both go by path rather than by value because the provider
    /// message channel drops a reply that is too large, without reporting an error and
    /// without a documented limit to stay under.
    private func requestExportedFile(_ command: ProviderCommand) async throws -> URL {
        guard let manager,
              let session = manager.connection as? NETunnelProviderSession,
              session.status == .connected else {
            throw NEManagerError.providerUnavailable
        }
        guard let message = command.rawValue.data(using: .utf8) else {
            throw NEManagerError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { data in
                    guard let data else {
                        continuation.resume(throwing: NEManagerError.exportFailed(
                            "the extension returned no reply to \(command.rawValue)"
                        ))
                        return
                    }
                    do {
                        let response = try JSONDecoder().decode(
                            ProviderMessageResponse.self, from: data
                        )
                        guard response.ok, let path = response.path else {
                            continuation.resume(throwing: NEManagerError.exportFailed(
                                response.error ?? "\(command.rawValue) failed"
                            ))
                            return
                        }
                        continuation.resume(returning: URL(fileURLWithPath: path))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func exportExtensionLogs() async throws -> URL {
        try await requestExportedFile(.exportOSLog)
    }

    func fetchDiagnostics() async throws -> URL {
        try await requestExportedFile(.diagnostics)
    }

    func clearCoreLog() async throws {
        guard let manager,
              let session = manager.connection as? NETunnelProviderSession,
              session.status == .connected else {
            throw NEManagerError.providerUnavailable
        }
        guard let message = ProviderCommand.clearLog.rawValue.data(using: .utf8) else {
            throw NEManagerError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { data in
                    guard let data else {
                        continuation.resume(throwing: NEManagerError.invalidResponse)
                        return
                    }
                    do {
                        let response = try JSONDecoder().decode(ProviderMessageResponse.self, from: data)
                        if response.ok {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: NEManagerError.clearFailed(response.error ?? "clear failed"))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @MainActor
    func setAlwaysOnEnabled(_ enabled: Bool) async throws {
        if status == .invalid || manager == nil {
            _ = try await NetworkExtensionManager.install()
            try await load()
        }
        guard let manager else {
            throw NEManagerError.providerUnavailable
        }
        manager.isEnabled = true
        if enabled {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
        } else {
            manager.onDemandRules = nil
        }
        manager.isOnDemandEnabled = enabled
        try await manager.saveToPreferences()
        isAlwaysOnEnabled = enabled
    }
}

class MockNEManager: NetworkExtensionManagerProtocol {
    @Published var status: NEVPNStatus = .disconnected
    @Published var connectedDate: Date? = nil
    @Published var isLoading: Bool = true
    @Published var isAlwaysOnEnabled: Bool = false

    // Simulate a successful load
    func load() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        isLoading = false
        status = .disconnected
    }

    // Simulate connecting
    func connect() async throws {
        status = .connecting
        // Simulate network delay
        try await Task.sleep(nanoseconds: 500_000_000)
        status = .connected
        connectedDate = Date()
    }

    func disconnect() async {
        status = .disconnecting
        try? await Task.sleep(nanoseconds: 500_000_000)
        status = .disconnected
        connectedDate = nil
    }

    func updateName(name: String, server: String) async { }

    func clearCoreLog() async throws { }

    func fetchRunningInfo(_ callback: @escaping ((NetworkStatus) -> Void)) {
        callback(MockNEManager.dummyRunningInfo)
    }

    func fetchLastNetworkSettings(_ callback: @escaping ((TunnelNetworkSettingsSnapshot?) -> Void)) {
        callback(nil)
    }

    func exportExtensionLogs() async throws -> URL {
        throw NetworkExtensionManager.NEManagerError.providerUnavailable
    }

    func fetchDiagnostics() async throws -> URL {
        throw NetworkExtensionManager.NEManagerError.providerUnavailable
    }

    @MainActor
    func setAlwaysOnEnabled(_ enabled: Bool) async throws {
        isAlwaysOnEnabled = enabled
    }
    
    static var dummyRunningInfo: NetworkStatus {
        let id = UUID().uuidString

        let myNodeInfo = NetworkStatus.MyNodeInfo(
            virtualIPv4: NetworkStatus.IPv4CIDR(address: NetworkStatus.IPv4Addr("10.144.144.10")!, networkLength: 24),
            hostname: "My iPhone",
            version: "0.10.1",
            ips: .init(
                publicIPv4: NetworkStatus.IPv4Addr("8.8.8.8"),
                interfaceIPv4s: [NetworkStatus.IPv4Addr("192.168.1.100")!],
                publicIPv6: nil as NetworkStatus.IPv6Addr?,
                interfaceIPv6s: []
            ),
            stunInfo: NetworkStatus.STUNInfo(udpNATType: .symmetricEasyInc, tcpNATType: .fullCone, lastUpdateTime: Date().timeIntervalSince1970 - 10),
            listeners: [NetworkStatus.Url(url: "tcp://0.0.0.0:11010"), NetworkStatus.Url(url: "udp://0.0.0.0:11010")],
            vpnPortalCfg: "[Interface]\nPrivateKey = [REDACTED]\nAddress = 10.144.144.1/24\nListenPort = 22022\n\n[Peer]\nPublicKey = [REDACTED]\nAllowedIPs = 10.144.144.2/32",
            peerID: 114514,
        )
        
        let peerRoute1 = NetworkStatus.Route(peerId: 123, ipv4Addr: .init(address: .init("10.144.144.10")!, networkLength: 24), nextHopPeerId: 123, cost: 1, pathLatency: 8, proxyCIDRs: [], hostname: "peer-1-ubuntu", stunInfo: NetworkStatus.STUNInfo(udpNATType: .fullCone, tcpNATType: .symmetric, lastUpdateTime: Date().timeIntervalSince1970 - 20), instId: id, version: "0.10.0")
        let peerRoute2 = NetworkStatus.Route(peerId: 456, ipv6Addr: .init(address: .init("fd00::1")!, networkLength: 64), nextHopPeerId: 789, cost: 2, pathLatency: 8, proxyCIDRs: [], hostname: "peer-2-relayed-windows", stunInfo: NetworkStatus.STUNInfo(udpNATType: .symmetric, tcpNATType: .restricted, lastUpdateTime: Date().timeIntervalSince1970 - 30), instId: id, version: "0.9.8")
        let peerRoute3 = NetworkStatus.Route(peerId: 256, ipv4Addr: .init(address: .init("10.144.144.14")!, networkLength: 32), ipv6Addr: .init(address: .init("fd00::2")!, networkLength: 48), nextHopPeerId: 789, cost: 1, pathLatency: 8, proxyCIDRs: [], hostname: "peer-3-relayed-verylong-verylong-verylong-verylong", stunInfo: NetworkStatus.STUNInfo(udpNATType: .openInternet, tcpNATType: .openInternet, lastUpdateTime: Date().timeIntervalSince1970 - 20), instId: id, version: "1.9.8")
        
        let conn1 = NetworkStatus.PeerConnInfo(connId: "conn-1", myPeerId: 0, isClient: true, peerId: 123, features: [], tunnel: NetworkStatus.TunnelInfo(tunnelType: "tcp", localAddr: NetworkStatus.Url(url:"192.168.1.100:55555"), remoteAddr: NetworkStatus.Url(url:"1.2.3.4:11010")), stats: NetworkStatus.PeerConnStats(rxBytes: 102400, txBytes: 204800, rxPackets: 100, txPackets: 200, latencyUs: 180000), lossRate: 0.01)
        let conn2 = NetworkStatus.PeerConnInfo(connId: "conn-2", myPeerId: 0, isClient: true, peerId: 256, features: [], tunnel: NetworkStatus.TunnelInfo(tunnelType: "udp", localAddr: NetworkStatus.Url(url:"192.168.1.100:55555"), remoteAddr: NetworkStatus.Url(url:"1.2.3.4:11010")), stats: NetworkStatus.PeerConnStats(rxBytes: 102400, txBytes: 204800, rxPackets: 100, txPackets: 200, latencyUs: 5000), lossRate: 0.01)

        let peer1 = NetworkStatus.PeerInfo(peerId: 123, conns: [conn1])
        let peer2 = NetworkStatus.PeerInfo(peerId: 256, conns: [conn1, conn2])
        
        return NetworkStatus(
            devName: "utun10",
            myNodeInfo: myNodeInfo,
            events: [
                "{\"time\":\"2026-01-04T14:31:55.012731+08:00\",\"event\":{\"PeerAdded\":4129348860}}",
                "{\"time\":\"2026-01-04T14:31:55.012711+08:00\",\"event\":{\"PeerConnAdded\":{\"conn_id\":\"11fdb3dd-9f35-4ab3-b255-133f1c7dad38\",\"my_peer_id\":3967454550,\"peer_id\":4129348860,\"features\":[],\"tunnel\":{\"tunnel_type\":\"tcp\",\"local_addr\":{\"url\":\"tcp://192.168.31.19:58758\"},\"remote_addr\":{\"url\":\"tcp://public.easytier.top:11010\"}},\"stats\":{\"rx_bytes\":91,\"tx_bytes\":93,\"rx_packets\":1,\"tx_packets\":1,\"latency_us\":0},\"loss_rate\":0.0,\"is_client\":true,\"network_name\":\"sijie-easytier-public\",\"is_closed\":false}}}",
                "{\"time\":\"2026-01-04T14:31:54.872468+08:00\",\"event\":{\"ListenerAdded\":\"wg://0.0.0.0:11011\"}}",
                "{\"time\":\"2026-01-04T14:31:54.866061+08:00\",\"event\":{\"Connecting\":\"tcp://public.easytier.top:11010\"}}",
                "{\"time\":\"2026-01-04T14:31:53.869940+08:00\",\"event\":{\"ListenerAdded\":\"wg://[::]:11011\"}}",
                "{\"time\":\"2026-01-04T14:31:53.869581+08:00\",\"event\":{\"ListenerAddFailed\":[\"wg://0.0.0.0:11011\",\"error: IOError(Os { code: 48, kind: AddrInUse, message: \\\"Address already in use\\\" }), retry listen later...\"]}}",
                "{\"time\":\"2026-01-04T14:31:53.868529+08:00\",\"event\":{\"ListenerAdded\":\"udp://[::]:11010\"}}",
                "{\"time\":\"2026-01-04T14:31:53.868207+08:00\",\"event\":{\"ListenerAdded\":\"udp://0.0.0.0:11010\"}}",
                "{\"time\":\"2026-01-04T14:31:53.865719+08:00\",\"event\":{\"ListenerAdded\":\"tcp://0.0.0.0:11010\"}}",
                "{\"time\":\"2026-01-04T14:31:53.865237+08:00\",\"event\":{\"ListenerAdded\":\"tcp://[::]:11010\"}}",
                "{\"time\":\"2026-01-04T14:31:53.863019+08:00\",\"event\":{\"ListenerAdded\":\"ring://360e18ba-81de-4bd0-b32a-07958ee9c917\"}}"
            ],
            routes: [peerRoute1, peerRoute2, peerRoute3],
            peers: [peer1, peer2],
            peerRoutePairs: [
                NetworkStatus.PeerRoutePair(route: peerRoute1, peer: peer1),
                NetworkStatus.PeerRoutePair(route: peerRoute2, peer: nil),
                NetworkStatus.PeerRoutePair(route: peerRoute3, peer: peer2)
            ],
            running: true,
            errorMsg: nil
        )
    }
}
