@preconcurrency import NetworkExtension
// Explicit, not inherited through NetworkExtension: this target builds in Swift 6 mode
// with MEMBER_IMPORT_VISIBILITY on, and FileManager / Bundle / PropertyListSerialization
// are used directly below.
import Foundation
import os

public let APP_BUNDLE_ID: String = "cn.easytier"
public let ICLOUD_CONTAINER_ID: String = "iCloud.cn.easytier"
public let LOG_FILENAME: String = "easytier.log"

private let DEFAULT_APP_GROUP_ID: String = "group.cn.easytier"

/// An App Group identifier is globally unique to the team that registered it, so re-signing
/// an IPA with a third-party certificate cannot keep `group.cn.easytier`: the entitlement is
/// renamed to whatever that certificate's profile grants rather than dropped. Lookups of the
/// hardcoded name then return nil -- no log file, no shared defaults, no widget -- while the
/// tunnel keeps running, because `packet-tunnel-provider` is a value any team can be granted.
/// So fall back to the group our own embedded profile grants. App Store builds carry no
/// profile and keep the default.
private let resolvedAppGroup: (id: String, source: String, available: Bool) = {
    let hasContainer = { (group: String) in
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }
    if hasContainer(DEFAULT_APP_GROUP_ID) { return (DEFAULT_APP_GROUP_ID, "default", true) }

    // A provisioning profile is a CMS envelope around a plain-text plist, and the system
    // verified that signature at install time, so lifting the payload out is enough here.
    guard let profile = try? Data(contentsOf: Bundle.main.bundleURL
            .appendingPathComponent("embedded.mobileprovision")) else {
        return (DEFAULT_APP_GROUP_ID, "no-profile", false)
    }
    guard let start = profile.range(of: Data("<?xml".utf8)),
          let end = profile.range(of: Data("</plist>".utf8), options: .backwards),
          let plist = (try? PropertyListSerialization.propertyList(
              from: Data(profile[start.lowerBound..<end.upperBound]),
              options: [],
              format: nil
          )) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let groups = entitlements["com.apple.security.application-groups"] as? [String]
    else { return (DEFAULT_APP_GROUP_ID, "unreadable-profile", false) }

    guard let usable = groups.first(where: hasContainer) else {
        // The profile granted groups, yet none of their containers exist. Worth telling
        // apart from the cases above: it means the re-sign left the entitlement and the
        // container out of step, which no fallback here can repair.
        return (DEFAULT_APP_GROUP_ID, "profile-has-\(groups.count)-none-usable", false)
    }
    return (usable, "profile", true)
}()

public let APP_GROUP_ID: String = resolvedAppGroup.id

/// Which of the branches above produced `APP_GROUP_ID`. Diagnostics print it because the
/// failure is otherwise indistinguishable at runtime: a wrong group disables the log file,
/// the shared defaults and the widget at once, and leaves the tunnel working.
public let APP_GROUP_SOURCE: String = resolvedAppGroup.source

/// Whether `APP_GROUP_ID` names a container this process can actually reach. Resolved here,
/// once, rather than by re-running `containerURL(forSecurityApplicationGroupIdentifier:)` at
/// each use: the answer cannot change while the process lives, and callers that need it in a
/// SwiftUI body would otherwise put a syscall on the main thread per render.
public let APP_GROUP_AVAILABLE: Bool = resolvedAppGroup.available

/// Whether the diagnostic telemetry stream is on.
///
/// Lives in the shared defaults so the app and the extension agree on it and so flipping the
/// switch takes effect on the next connect rather than needing a new build. On unless it has
/// been explicitly switched off: it is what makes a problem reportable without anyone having
/// to export a file by hand, and an absent key means nobody has expressed a preference yet.
public let TELEMETRY_ENABLED_KEY: String = "diagnosticsTelemetry"

/// `nonisolated` because both callers reach it from a background queue -- the extension's
/// settings queue and the app's telemetry queue -- and this target infers MainActor for
/// anything unannotated. Same reason `TextItem` is declared that way.
public nonisolated func isTelemetryEnabled() -> Bool {
    guard let defaults = UserDefaults(suiteName: APP_GROUP_ID),
          defaults.object(forKey: TELEMETRY_ENABLED_KEY) != nil else {
        return true
    }
    return defaults.bool(forKey: TELEMETRY_ENABLED_KEY)
}

public enum LogLevel: String, Codable, CaseIterable {
    case trace = "trace"
    case debug = "debug"
    case info = "info"
    case warn = "warn"
    case error = "error"
}

public struct EasyTierOptions: Codable {
    public var config: String = ""
    public var ipv4: String?
    public var ipv6: String?
    public var mtu: Int?
    public var routes: [String] = []
    public var logLevel: LogLevel = .info
    public var magicDNS: Bool = false
    public var dns: [String] = []
    /// Optional rather than an empty array, because a synthesised Decodable throws on a
    /// missing non-optional key: an always-on tunnel can reconnect on an options blob
    /// written by the previous build, and that must not stop it from starting.
    public var exitNodes: [String]?

    public init() {}
}

public struct TunnelNetworkSettingsSnapshot: Codable, Equatable {
    public struct IPv4Subnet: Codable, Hashable {
        public var address: String
        public var subnetMask: String

        public init(address: String, subnetMask: String) {
            self.address = address
            self.subnetMask = subnetMask
        }
    }

    public struct IPv6Subnet: Codable, Hashable {
        public var address: String
        public var networkPrefixLength: Int

        public init(address: String, networkPrefixLength: Int) {
            self.address = address
            self.networkPrefixLength = networkPrefixLength
        }
    }

    public struct IPv4: Codable, Equatable {
        public var subnets: Set<IPv4Subnet>
        public var includedRoutes: Set<IPv4Subnet>?
        public var excludedRoutes: Set<IPv4Subnet>?

        public init(
            addresses: [String],
            subnetMasks: [String],
            includedRoutes: [IPv4Subnet]? = nil,
            excludedRoutes: [IPv4Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv4Subnet(address: address, subnetMask: subnetMasks[index])
                )
            }
            if let includedRoutes, !includedRoutes.isEmpty {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes, !excludedRoutes.isEmpty {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct IPv6: Codable, Equatable {
        public var subnets: Set<IPv6Subnet>
        public var includedRoutes: Set<IPv6Subnet>?
        public var excludedRoutes: Set<IPv6Subnet>?

        public init(
            addresses: [String],
            networkPrefixLengths: [Int],
            includedRoutes: [IPv6Subnet]? = nil,
            excludedRoutes: [IPv6Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv6Subnet(
                        address: address,
                        networkPrefixLength: networkPrefixLengths[index]
                    )
                )
            }
            if let includedRoutes {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct DNS: Codable, Equatable {
        public var servers: Set<String>
        public var searchDomains: Set<String>?
        public var matchDomains: Set<String>?

        public init(
            servers: [String],
            searchDomains: [String]? = nil,
            matchDomains: [String]? = nil
        ) {
            self.servers = Set(servers)
            if let searchDomains {
                self.searchDomains = Set(searchDomains)
            }
            if let matchDomains {
                self.matchDomains = Set(matchDomains)
            }
        }
    }

    public var ipv4: IPv4?
    public var ipv6: IPv6?
    public var dns: DNS?
    public var mtu: UInt32?

    public init(ipv4: IPv4? = nil, ipv6: IPv6? = nil, dns: DNS? = nil, mtu: UInt32? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.dns = dns
        self.mtu = mtu
    }
}

public enum ProviderCommand: String, Codable, CaseIterable {
    case clearLog = "clear_log"
    case exportOSLog = "export_oslog"
    case runningInfo = "running_info"
    case lastNetworkSettings = "last_network_settings"
    // Returns diagnostics as plain UTF-8 text in the reply body, rather than a path
    // into the App Group container the way exportOSLog does. On a re-signed build that
    // container is unreachable, which takes out every other way of getting logs off
    // the device -- so this one deliberately depends on nothing but the provider
    // message channel itself.
    case diagnostics = "diagnostics"
}

public enum TunnelManagerError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "EasyTier VPN configuration is unavailable."
        }
    }
}

private func configureManagerForConnection(_ manager: NETunnelProviderManager, logger: Logger?) {
    manager.isEnabled = true
    if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
        manager.protocolConfiguration?.includeAllNetworks = defaults.bool(forKey: "includeAllNetworks")
        manager.protocolConfiguration?.excludeLocalNetworks = defaults.bool(forKey: "excludeLocalNetworks")
        if #available(iOS 16.4, macOS 13.3, *) {
            manager.protocolConfiguration?.excludeCellularServices = defaults.bool(forKey: "excludeCellularServices")
            manager.protocolConfiguration?.excludeAPNs = defaults.bool(forKey: "excludeAPNs")
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            manager.protocolConfiguration?.excludeDeviceCommunication = defaults.bool(forKey: "excludeDeviceCommunication")
        }
        manager.protocolConfiguration?.enforceRoutes = defaults.bool(forKey: "enforceRoutes")
        if let logger {
            logger.debug("connect with protocol configuration: \(manager.protocolConfiguration)")
        }
    }
}

public func connectWithManager(_ manager: NETunnelProviderManager, logger: Logger? = nil) async throws {
    configureManagerForConnection(manager, logger: logger)
    try await manager.saveToPreferences()
    try manager.connection.startVPNTunnel()
}

public func connectWithManager(_ manager: NETunnelProviderManager, logger: Logger? = nil, completionHandler: (@Sendable ((any Error)?) -> Void)? = nil) {
    configureManagerForConnection(manager, logger: logger)
    manager.saveToPreferences() { error in
        if let error {
            completionHandler?(error)
            return
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            completionHandler?(error)
            return
        }
        completionHandler?(nil)
    }
}
