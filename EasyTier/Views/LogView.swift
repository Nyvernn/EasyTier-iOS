import SwiftUI
import NetworkExtension
import EasyTierShared

private func logFileURL() -> URL? {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID)?
        .appendingPathComponent(LOG_FILENAME)
}

struct LogView<Manager: NetworkExtensionManagerProtocol>: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var manager: Manager
    @StateObject private var tailer = LogTailer()
    @Namespace private var bottomID
    @State private var wasWatchingBeforeBackground = false
#if os(iOS)
    @State private var exportURL: URL?
    @State private var isExportPresented = false
#endif
    @State private var exportErrorMessage: TextItem?
    /// Log text fetched straight from the extension, used when the App Group container is
    /// unreachable and the tailer therefore has nothing to read. Non-empty means the view
    /// is showing a snapshot rather than a live tail.
    @State private var pulledLines: [String] = []
    @State private var isPulling = false
    @State private var pullAttempt = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                containerBanner
                // Log Content
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading) {
                            if pulledLines.isEmpty {
                                ForEach(tailer.logContent) { line in
                                    Text(line.text)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            } else {
                                // By index, because a log can repeat a line verbatim and
                                // identical ids would collapse them in the list.
                                ForEach(pulledLines.indices, id: \.self) { index in
                                    Text(pulledLines[index])
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            Text("").id(bottomID)
                        }
                        .padding()
                        .onChange(of: tailer.logContent) { _ in
                            // Auto-scroll to bottom on update
                            withAnimation {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                }
#if os(iOS)
                .background(Color(UIColor.systemGroupedBackground))
#endif
            }
            .navigationTitle("logging")
            .adaptiveNavigationBarTitleInline()
            .toolbar {
                ToolbarItem(placement: ToolbarLeading) {
                    Button(action: {
                        Task {
                            await clearLog()
                        }
                    }) {
                        Image(systemName: "trash")
                    }.tint(.red)
                }
                ToolbarItem(placement: ToolbarTrailing) {
                    Button(action: {
                        presentExport()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                // Pull the extension's own buffer over the provider message channel. The
                // tailer can only ever read the App Group container, so when a re-signed
                // build cannot reach that container this page is blank no matter what the
                // extension logged -- this is the way in that does not depend on it.
                ToolbarItem(placement: ToolbarTrailing) {
                    Button(action: {
                        pullFromExtension()
                    }) {
                        if isPulling {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .disabled(isPulling || manager.status == .disconnected)
                }
                ToolbarItem(placement: ToolbarTrailing) {
                    Button(action: {
                        if tailer.isWatching {
                            tailer.stop()
                        } else {
                            // Resuming the live tail also drops the snapshot, otherwise it
                            // would keep shadowing the lines arriving underneath it.
                            pulledLines = []
                            tailer.startWatching(appGroupID: APP_GROUP_ID, filename: LOG_FILENAME, fromStart: false)
                        }
                    }) {
                        Image(systemName: tailer.isWatching ? "pause" : "play")
                    }
                }
            }
        }
        .onAppear {
            // Not while a snapshot is showing: the tailer's output would be hidden behind
            // it, so starting it would only burn a file watcher on nothing.
            if !tailer.isWatching, pulledLines.isEmpty {
                tailer.startWatching(appGroupID: APP_GROUP_ID, filename: LOG_FILENAME, fromStart: true)
            }
        }
        .onDisappear {
            tailer.stop()
            wasWatchingBeforeBackground = false
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if wasWatchingBeforeBackground {
                    tailer.startWatching(appGroupID: APP_GROUP_ID, filename: LOG_FILENAME, fromStart: false)
                    wasWatchingBeforeBackground = false
                }
            case .inactive, .background:
                wasWatchingBeforeBackground = tailer.isWatching
                tailer.stop()
            @unknown default:
                break
            }
        }
        .alert(item: $tailer.errorMessage) { msg in
            Alert(title: Text("common.error"), message: Text(msg.text))
        }
        .alert(item: $exportErrorMessage) { msg in
            Alert(title: Text("common.error"), message: Text(msg.text))
        }
#if os(iOS)
        .sheet(isPresented: $isExportPresented) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
#endif
    }

    /// Says which App Group was resolved and how.
    ///
    /// Without it, an empty page has three indistinguishable causes: the tunnel never
    /// started, the Rust logger failed, or this signature simply cannot reach the
    /// container. Only the third one is answered by pulling instead, and only this line
    /// tells them apart -- APP_GROUP_SOURCE names the branch that produced the id, so a
    /// value other than "default" or "profile" is itself the diagnosis.
    private var containerBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: APP_GROUP_AVAILABLE
                ? "checkmark.circle" : "exclamationmark.triangle")
            Text(verbatim: "\(APP_GROUP_ID) (\(APP_GROUP_SOURCE))"
                + (APP_GROUP_AVAILABLE ? "" : " - unreachable, pull instead")
                + (pulledLines.isEmpty ? "" : " - snapshot, press play for live"))
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(APP_GROUP_AVAILABLE ? .secondary : .orange)
        .padding(.horizontal)
    }

    private func pullFromExtension() {
        guard !isPulling else { return }
        isPulling = true
        pullAttempt += 1
        let attempt = pullAttempt

        // sendProviderMessage never promises to call its handler back, so bound the wait.
        // It happens here, on the main actor, because doing it around the continuation
        // would give that continuation two resume paths and resuming twice traps. The
        // attempt number is what keeps a late reply from disturbing a newer request.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15 * NSEC_PER_SEC)
            guard isPulling, pullAttempt == attempt else { return }
            isPulling = false
            pulledLines = ["<the extension did not answer within 15s>"]
        }

        Task {
            let lines: [String]
            do {
                let url = try await manager.fetchDiagnostics()
                let data = try Data(contentsOf: url)
                lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            } catch {
                lines = ["<pull failed: \(error)>"]
            }
            await MainActor.run {
                guard pullAttempt == attempt else { return }
                isPulling = false
                // A snapshot and a live tail of the same file would interleave out of
                // order, so stop the tailer while the snapshot is on screen.
                tailer.stop()
                pulledLines = lines
            }
        }
    }

    private func presentExport() {
        // Prefer what is on screen: when the container is unreachable the file below does
        // not exist, and refusing to export a snapshot the user can already see is the
        // least useful thing to do with it.
        if !pulledLines.isEmpty {
            let snapshot = FileManager.default.temporaryDirectory
                .appendingPathComponent("easytier-log-snapshot.txt")
            let body = Data(pulledLines.joined(separator: "\n").utf8)
            if (try? body.write(to: snapshot, options: .atomic)) != nil {
                presentExport(of: snapshot)
                return
            }
        }
        guard let url = logFileURL() else {
            exportErrorMessage = .init("Log file not found.")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            exportErrorMessage = .init("Log file not found.")
            return
        }
        presentExport(of: url)
    }

    private func presentExport(of url: URL) {
#if os(iOS)
        exportURL = url
        isExportPresented = true
#elseif os(macOS)
        do {
            try saveExportedFileToDisk(url)
        } catch {
            exportErrorMessage = .init(error.localizedDescription)
        }
#endif
    }

    private func clearLog() async {
        let providerClear: (() async throws -> Void)?
        if shouldUseProviderClear {
            providerClear = { try await manager.clearCoreLog() }
        } else {
            providerClear = nil
        }
        await tailer.clear(appGroupID: APP_GROUP_ID, filename: LOG_FILENAME, providerClear: providerClear)
    }

    private var shouldUseProviderClear: Bool {
        switch manager.status {
        case .connecting, .connected, .reasserting:
            return true
        case .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return true
        }
    }
}

#if DEBUG
#Preview("Log") {
    LogView(manager: MockNEManager())
}
#endif
