import SwiftUI
import NetworkExtension
import EasyTierShared

let sharedDefaults = UserDefaults(suiteName: APP_GROUP_ID)

struct SettingsView<Manager: NetworkExtensionManagerProtocol>: View {
    @ObservedObject var manager: Manager
    @ObservedObject var selectedSession: SelectedProfileSession
    @AppStorage("logLevel") var logLevel: LogLevel = .info
    @AppStorage("statusRefreshInterval") var statusRefreshInterval: Double = 1.0
    @AppStorage("logPreservedLines") var logPreservedLines: Int = 1000
    @AppStorage("useRealDeviceNameAsDefault") var useRealDeviceNameAsDefault: Bool = true
#if os(iOS)
    @AppStorage("plainTextIPInput") var plainTextIPInput: Bool = false
#endif
    @AppStorage("profilesUseICloud") var profilesUseICloud: Bool = false
    @AppStorage("selectedProfileName", store: sharedDefaults) var lastSelected: String?
    @AppStorage("includeAllNetworks", store: sharedDefaults) var includeAllNetworks: Bool = false
    @AppStorage("excludeLocalNetworks", store: sharedDefaults) var excludeLocalNetworks: Bool = false
    @AppStorage("excludeCellularServices", store: sharedDefaults) var excludeCellularServices: Bool = true
    @AppStorage("excludeAPNs", store: sharedDefaults) var excludeAPNs: Bool = true
    @AppStorage("excludeDeviceCommunication", store: sharedDefaults) var excludeDeviceCommunication: Bool = true
    @AppStorage("enforceRoutes", store: sharedDefaults) var enforceRoutes: Bool = false
    @State private var selectedPane: SettingsPane?
#if os(iOS)
    @State private var exportURL: URL?
    @State private var isExportPresented = false
#endif
    @State private var settingsErrorMessage: TextItem?
    @State private var isExporting = false
    @State private var isAlwaysOnUpdating = false
    @State private var isProfileStorageUpdating = false
    @State private var pendingProfileStorageTransition: PendingProfileStorageTransition?
    @State private var profileMigrationConflict: ProfileStore.ProfileMigrationConflict?
    @State private var showResetAlert: Bool = false
    
    init(manager: Manager, selectedSession: SelectedProfileSession) {
        _manager = ObservedObject(wrappedValue: manager)
        _selectedSession = ObservedObject(wrappedValue: selectedSession)
    }

    enum SettingsPane: Identifiable, Hashable {
        var id: Self { self }
        case license
    }

    private struct PendingProfileStorageTransition {
        let enabled: Bool
        let previousSession: ProfileSession?
        let profileNameToRestore: String?
        let plan: ProfileStore.ProfileMigrationPlan
        var conflictIndex: Int
        var overwriteDestinations: Set<URL>
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "not_available")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? String(localized: "not_available")
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            AdaptiveNavigation(primaryColumn, secondaryColumn, showNav: $selectedPane)
                .navigationTitle("settings")
                .adaptiveNavigationBarTitleInline()
                .scrollDismissesKeyboard(.immediately)
        }
    }
    
    var primaryColumn: some View {
        Group {
#if os(iOS)
            List(selection: $selectedPane) {
                settingsContent
            }
#else
            Form {
                settingsContent
            }
            .formStyle(.grouped)
#endif
        }
        .alert(item: $settingsErrorMessage) { msg in
            Alert(title: Text("common.error"), message: Text(msg.text))
        }
        .alert(isPresented: $showResetAlert) {
            Alert(
                title: Text("reset_to_default"),
                message: Text("reset_to_default_confirm"),
                primaryButton: .destructive(Text("reset")) {
                    let currentProfileStorage = profilesUseICloud
                    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                    // Storage changes require the migration transaction above;
                    // resetting unrelated settings must not switch backends.
                    UserDefaults.standard.set(currentProfileStorage, forKey: "profilesUseICloud")
                    UserDefaults.standard.synchronize()
                    if let sharedDefaults {
                        sharedDefaults.removePersistentDomain(forName: APP_GROUP_ID)
                        sharedDefaults.synchronize()
                    }
                },
                secondaryButton: .cancel(),
            )
        }
        .alert(item: $profileMigrationConflict) { conflict in
            Alert(
                title: Text("profile_storage_conflict_title"),
                message: Text(
                    "\(conflict.fileName)\n\n\(String(localized: "profile_storage_conflict_message"))"
                ),
                primaryButton: .destructive(Text("profile_storage_conflict_overwrite")) {
                    resolveProfileMigrationConflict(overwrite: true)
                },
                secondaryButton: .default(Text("profile_storage_conflict_keep")) {
                    resolveProfileMigrationConflict(overwrite: false)
                }
            )
        }
#if os(iOS)
        .sheet(isPresented: $isExportPresented) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
#endif
    }
    
    var secondaryColumn: some View {
        Group {
            switch selectedPane {
            case .license:
                openSourceLicenseView
            case nil:
                ZStack {
#if os(iOS)
                    Color(.systemGroupedBackground)
#endif
                    Image(systemName: "network")
                        .resizable()
                        .frame(width: 128, height: 128)
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                }
                .ignoresSafeArea()
            }
        }
    }
    
    var settingsContent: some View {
        Group {
            Section("general") {
                LabeledContent("status_refresh_rate") {
                    HStack {
                        TextField(
                            "1.0",
                            value: $statusRefreshInterval,
                            formatter: NumberFormatter(),
                            prompt: Text("1.0")
                        )
                        .labelsHidden()
                        .contentShape(Rectangle())
                        .multilineTextAlignment(.trailing)
                        .decimalKeyboardType()
                        Text("s")
                    }
                }
                Toggle("use_device_name", isOn: $useRealDeviceNameAsDefault)
#if os(iOS)
                Toggle("plain_text_ip_input", isOn: $plainTextIPInput)
#endif
                Toggle("save_to_icloud", isOn: profilesUseICloudBinding)
                    .disabled(isProfileStorageUpdating)
                Toggle("always_on", isOn: $manager.isAlwaysOnEnabled)
                    .disabled(manager.isLoading || isAlwaysOnUpdating)
                    .onChange(of: manager.isAlwaysOnEnabled) { newValue in
                        updateAlwaysOn(newValue)
                    }
            }

            Section {
                Picker("log_level", selection: $logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.uppercased()).tag(level)
                    }
                }
                .disabled(manager.status != .disconnected)
                LabeledContent("log_preserved_lines") {
                    TextField(
                        "1000",
                        value: $logPreservedLines,
                        formatter: NumberFormatter(),
                        prompt: Text("1000")
                    )
                    .labelsHidden()
                    .contentShape(Rectangle())
                    .multilineTextAlignment(.trailing)
                    .numberKeyboardType()
                }
                Button(action: {
                    exportOSLog()
                }) {
                    HStack {
                        Text("export_oslog")
                        Spacer()
                        if isExporting {
#if os(iOS)
                            ProgressView()
#endif
                        }
                    }
                }
#if os(macOS)
                .buttonStyle(.borderless)
                .tint(.accentColor)
#endif
                .disabled(isExporting || manager.status == .disconnected)
            } header: {
                Text("logging")
            } footer: {
                Text("logging_help")
            }
            
            Section {
                Toggle("include_all_networks", isOn: $includeAllNetworks)
                Toggle("exclude_local_networks", isOn: $excludeLocalNetworks)
                Toggle("exclude_cellular_services", isOn: $excludeCellularServices)
                Toggle("exclude_apns", isOn: $excludeAPNs)
                Toggle("exclude_device_communication", isOn: $excludeDeviceCommunication)
                Toggle("enforce_routes", isOn: $enforceRoutes)
            } header: {
                Text("advanced")
            } footer: {
                Text("advanced_help")
            }
            .disabled(manager.status != .disconnected)
            
            Button("reset_to_default", role: .destructive) {
                showResetAlert = true
            }
#if os(macOS)
            .buttonStyle(.borderless)
            .tint(.red)
#endif

            Section("about.title") {
                LabeledContent("app") {
                    Text("EasyTier")
                }
                LabeledContent("version") {
                    Text(appVersion)
                }
                Link("about.homepage", destination: URL(string: "https://github.com/EasyTier/EasyTier-iOS")!)
                Link("about.privacy_policy", destination: URL(string: "https://easytier.cn/guide/privacy.html")!)
                
#if os(iOS)
                NavigationLink("about.license", value: SettingsPane.license)
#else
                NavigationLink("about.license") {
                    openSourceLicenseView
                }
#endif
            }
        }
    }
    
    var openSourceLicenseView: some View {
        List {
            Section("EasyTier-iOS") {
                Text("""
            Copyright (C) 2026  Chenx Dust and Yin Mo
            
            This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
            
            This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
            
            You should have received a copy of the GNU General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.
            """)
                .font(.caption.monospaced())
            }
            Section("EasyTier") {
                Text("""
            GNU LESSER GENERAL PUBLIC LICENSE

            Version 3, 29 June 2007

            Copyright © 2007 Free Software Foundation, Inc. <https://fsf.org/>

            Everyone is permitted to copy and distribute verbatim copies of this license document, but changing it is not allowed.

            This version of the GNU Lesser General Public License incorporates the terms and conditions of version 3 of the GNU General Public License, supplemented by the additional permissions listed below.

            0. Additional Definitions.

            As used herein, “this License” refers to version 3 of the GNU Lesser General Public License, and the “GNU GPL” refers to version 3 of the GNU General Public License.

            “The Library” refers to a covered work governed by this License, other than an Application or a Combined Work as defined below.

            An “Application” is any work that makes use of an interface provided by the Library, but which is not otherwise based on the Library. Defining a subclass of a class defined by the Library is deemed a mode of using an interface provided by the Library.

            A “Combined Work” is a work produced by combining or linking an Application with the Library. The particular version of the Library with which the Combined Work was made is also called the “Linked Version”.

            The “Minimal Corresponding Source” for a Combined Work means the Corresponding Source for the Combined Work, excluding any source code for portions of the Combined Work that, considered in isolation, are based on the Application, and not on the Linked Version.

            The “Corresponding Application Code” for a Combined Work means the object code and/or source code for the Application, including any data and utility programs needed for reproducing the Combined Work from the Application, but excluding the System Libraries of the Combined Work.

            1. Exception to Section 3 of the GNU GPL.

            You may convey a covered work under sections 3 and 4 of this License without being bound by section 3 of the GNU GPL.

            2. Conveying Modified Versions.

            If you modify a copy of the Library, and, in your modifications, a facility refers to a function or data to be supplied by an Application that uses the facility (other than as an argument passed when the facility is invoked), then you may convey a copy of the modified version:

            a) under this License, provided that you make a good faith effort to ensure that, in the event an Application does not supply the function or data, the facility still operates, and performs whatever part of its purpose remains meaningful, or
            b) under the GNU GPL, with none of the additional permissions of this License applicable to that copy.
            3. Object Code Incorporating Material from Library Header Files.

            The object code form of an Application may incorporate material from a header file that is part of the Library. You may convey such object code under terms of your choice, provided that, if the incorporated material is not limited to numerical parameters, data structure layouts and accessors, or small macros, inline functions and templates (ten or fewer lines in length), you do both of the following:

            a) Give prominent notice with each copy of the object code that the Library is used in it and that the Library and its use are covered by this License.
            b) Accompany the object code with a copy of the GNU GPL and this license document.
            4. Combined Works.

            You may convey a Combined Work under terms of your choice that, taken together, effectively do not restrict modification of the portions of the Library contained in the Combined Work and reverse engineering for debugging such modifications, if you also do each of the following:

            a) Give prominent notice with each copy of the Combined Work that the Library is used in it and that the Library and its use are covered by this License.
            b) Accompany the Combined Work with a copy of the GNU GPL and this license document.
            c) For a Combined Work that displays copyright notices during execution, include the copyright notice for the Library among these notices, as well as a reference directing the user to the copies of the GNU GPL and this license document.
            d) Do one of the following:
            0) Convey the Minimal Corresponding Source under the terms of this License, and the Corresponding Application Code in a form suitable for, and under terms that permit, the user to recombine or relink the Application with a modified version of the Linked Version to produce a modified Combined Work, in the manner specified by section 6 of the GNU GPL for conveying Corresponding Source.
            1) Use a suitable shared library mechanism for linking with the Library. A suitable mechanism is one that (a) uses at run time a copy of the Library already present on the user's computer system, and (b) will operate properly with a modified version of the Library that is interface-compatible with the Linked Version.
            e) Provide Installation Information, but only if you would otherwise be required to provide such information under section 6 of the GNU GPL, and only to the extent that such information is necessary to install and execute a modified version of the Combined Work produced by recombining or relinking the Application with a modified version of the Linked Version. (If you use option 4d0, the Installation Information must accompany the Minimal Corresponding Source and Corresponding Application Code. If you use option 4d1, you must provide the Installation Information in the manner specified by section 6 of the GNU GPL for conveying Corresponding Source.)
            5. Combined Libraries.

            You may place library facilities that are a work based on the Library side by side in a single library together with other library facilities that are not Applications and are not covered by this License, and convey such a combined library under terms of your choice, if you do both of the following:

            a) Accompany the combined library with a copy of the same work based on the Library, uncombined with any other library facilities, conveyed under the terms of this License.
            b) Give prominent notice with the combined library that part of it is a work based on the Library, and explaining where to find the accompanying uncombined form of the same work.
            6. Revised Versions of the GNU Lesser General Public License.

            The Free Software Foundation may publish revised and/or new versions of the GNU Lesser General Public License from time to time. Such new versions will be similar in spirit to the present version, but may differ in detail to address new problems or concerns.

            Each version is given a distinguishing version number. If the Library as you received it specifies that a certain numbered version of the GNU Lesser General Public License “or any later version” applies to it, you have the option of following the terms and conditions either of that published version or of any later version published by the Free Software Foundation. If the Library as you received it does not specify a version number of the GNU Lesser General Public License, you may choose any version of the GNU Lesser General Public License ever published by the Free Software Foundation.

            If the Library as you received it specifies that a proxy can decide whether future versions of the GNU Lesser General Public License shall apply, that proxy's public statement of acceptance of any version is permanent authorization for you to choose that version for the Library.
            """)
                .font(.caption.monospaced())
            }
            Section("TOMLKit") {
                Text("""
            MIT License

            Copyright (c) 2024 Jeff Lebrun

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """)
                .font(.caption.monospaced())
            }
        }
        .navigationTitle("about.license")
    }

    private func exportOSLog() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                let url = try await manager.exportExtensionLogs()
                await MainActor.run {
#if os(iOS)
                    exportURL = url
                    isExportPresented = true
#elseif os(macOS)
                    do {
                        try saveExportedFileToDisk(url)
                    } catch {
                        settingsErrorMessage = .init(error.localizedDescription)
                    }
#endif
                }
            } catch {
                await MainActor.run {
                    settingsErrorMessage = .init(String(localized: "export_failed"))
                }
            }
            await MainActor.run {
                isExporting = false
            }
        }
    }

    private var profilesUseICloudBinding: Binding<Bool> {
        Binding(
            get: { profilesUseICloud },
            set: { updateProfileStorage($0) }
        )
    }

    private func updateProfileStorage(_ enabled: Bool) {
        guard enabled != profilesUseICloud, !isProfileStorageUpdating else { return }
        isProfileStorageUpdating = true

        Task { @MainActor in
            let previousSession = selectedSession.session
            let profileNameToRestore = previousSession?.name ?? lastSelected

            do {
                if let session = previousSession {
                    // Remove the session first so a delayed Dashboard
                    // autosave cannot race the migration. Saving the captured
                    // session drains any work already queued for it.
                    selectedSession.session = nil
                    lastSelected = profileNameToRestore
                    try await session.save()
                }

                let plan = try ProfileStore.prepareProfileMigration(useICloud: enabled)
                let transition = PendingProfileStorageTransition(
                    enabled: enabled,
                    previousSession: previousSession,
                    profileNameToRestore: profileNameToRestore,
                    plan: plan,
                    conflictIndex: 0,
                    overwriteDestinations: []
                )
                pendingProfileStorageTransition = transition

                if let firstConflict = plan.conflicts.first {
                    profileMigrationConflict = firstConflict
                } else {
                    await finishProfileStorageTransition(transition)
                }
            } catch {
                if let previousSession {
                    selectedSession.session = previousSession
                }
                settingsErrorMessage = .init(error.localizedDescription)
                clearProfileStorageTransition()
            }
        }
    }

    private func resolveProfileMigrationConflict(overwrite: Bool) {
        guard var transition = pendingProfileStorageTransition,
              transition.conflictIndex < transition.plan.conflicts.count else { return }
        let conflict = transition.plan.conflicts[transition.conflictIndex]
        if overwrite {
            transition.overwriteDestinations.insert(conflict.destinationURL)
        }
        transition.conflictIndex += 1
        pendingProfileStorageTransition = transition
        profileMigrationConflict = nil

        if transition.conflictIndex < transition.plan.conflicts.count {
            let nextConflict = transition.plan.conflicts[transition.conflictIndex]
            Task { @MainActor in
                await Task.yield()
                guard pendingProfileStorageTransition != nil else { return }
                profileMigrationConflict = nextConflict
            }
        } else {
            Task { @MainActor in
                await finishProfileStorageTransition(transition)
            }
        }
    }

    @MainActor
    private func finishProfileStorageTransition(
        _ transition: PendingProfileStorageTransition
    ) async {
        var transitionError: Error?
        do {
            try ProfileStore.executeProfileMigration(
                transition.plan,
                overwriting: transition.overwriteDestinations
            )

            if let previousSession = transition.previousSession {
                await previousSession.close()
            }

            // Commit the preference only after all per-file choices have been
            // applied successfully.
            profilesUseICloud = transition.enabled
        } catch {
            transitionError = error
            if let previousSession = transition.previousSession {
                selectedSession.session = previousSession
            }
        }

        // The preference is unchanged on failure, so this restores the
        // previous backend. On success it opens the selected profile from the
        // newly selected backend.
        if transitionError == nil,
           selectedSession.session == nil,
           let profileNameToRestore = transition.profileNameToRestore {
            do {
                selectedSession.session = try await ProfileStore.openSession(named: profileNameToRestore)
            } catch {
                if transitionError == nil {
                    transitionError = error
                }
            }
        }

        if let transitionError {
            settingsErrorMessage = .init(transitionError.localizedDescription)
        }
        clearProfileStorageTransition()
    }

    private func clearProfileStorageTransition() {
        pendingProfileStorageTransition = nil
        profileMigrationConflict = nil
        isProfileStorageUpdating = false
    }

    private func updateAlwaysOn(_ enabled: Bool) {
        guard !isAlwaysOnUpdating else { return }
        isAlwaysOnUpdating = true
        Task {
            do {
                try await manager.setAlwaysOnEnabled(enabled)
            } catch {
                await MainActor.run {
                    manager.isAlwaysOnEnabled = !enabled
                    settingsErrorMessage = .init(String(localized: "always_on_failed"))
                }
            }
            await MainActor.run {
                isAlwaysOnUpdating = false
            }
        }
    }
}

#if DEBUG
#Preview("Settings Portrait") {
    let manager = MockNEManager()
    SettingsView(manager: manager, selectedSession: SelectedProfileSession())
        .environmentObject(manager)
}
#endif
