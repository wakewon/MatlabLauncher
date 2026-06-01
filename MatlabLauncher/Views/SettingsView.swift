import SwiftUI
import KeyboardShortcuts

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var scheduler: JobScheduler
    @EnvironmentObject var serviceManager: ServiceManager
    @State private var settings: AppSettings = .default
    @State private var detectedMatlabs: [MATLABDetector.MATLABInstallation] = []
    @State private var selectedTab: SettingsTab = .general
    @Namespace private var tabSelection

    private let shortFieldWidth: CGFloat = 96
    private let menuControlWidth: CGFloat = 330
    private let pathFieldWidth: CGFloat = 470
    private let controlColumnWidth: CGFloat = 480

    private enum SettingsTab: String, CaseIterable, Hashable {
        case general
        case advanced

        var title: String {
            switch self {
            case .general: return "General"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .advanced: return "server.rack"
            }
        }
    }

    var body: some View {
        ZStack {
            settingsBackground

            VStack(spacing: 0) {
                topBar

                Group {
                    switch selectedTab {
                    case .general:
                        generalPane
                    case .advanced:
                        advancedPane
                    }
                }
            }
        }
        .frame(width: 860, height: 720)
        .animation(.snappy(duration: 0.2), value: selectedTab)
        .onAppear {
            settings = scheduler.settings
            detectedMatlabs = MATLABDetector.detectInstallations()
            serviceManager.refreshCLIStatus()
            serviceManager.probeNow()
        }
        .onChange(of: settings) { oldValue, newValue in
            saveSettings(previousSettings: oldValue, newSettings: newValue)
        }
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.72)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.title3.weight(.bold))

                Text("Matlab Launcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            tabSwitcher

            Button {
                settings = .default
            } label: {
                Label("Defaults", systemImage: "arrow.uturn.backward")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.38), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Restore default settings")
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 1)
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.26), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(tab.title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(width: 124, alignment: .center)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                        .matchedGeometryEffect(id: "selected-settings-tab", in: tabSelection)
                        .overlay {
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 1)
                        }
                        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var generalPane: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection("System", systemImage: "macwindow") {
                    settingsRow(
                        title: "Open Main Window",
                        subtitle: "Trigger Matlab Launcher from anywhere."
                    ) {
                        KeyboardShortcuts.Recorder(for: .toggleMainWindow)
                    }

                    settingsRow(
                        title: "Hide Dock Icon",
                        subtitle: "Run as menu bar app only. Disable to show in Dock."
                    ) {
                        Toggle("Enabled", isOn: $settings.hideDockIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                settingsSection("MATLAB", systemImage: "function") {
                    settingsRow(
                        title: "Default Tool",
                        subtitle: "Choose the MATLAB binary used for new tasks."
                    ) {
                        Picker("Default Tool", selection: $settings.defaultMatlabPath) {
                            ForEach(detectedMatlabs) { matlab in
                                Text(matlab.displayName).tag(matlab.binaryPath)
                            }
                            Text("Use Current Path").tag(settings.defaultMatlabPath)
                        }
                        .pickerStyle(.menu)
                        .frame(width: menuControlWidth, alignment: .trailing)
                    }

                    settingsRow(
                        title: "Binary Path",
                        subtitle: "Override the executable path if detection is incorrect."
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
                            TextField("Path", text: $settings.defaultMatlabPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: pathFieldWidth)

                            Button {
                                detectedMatlabs = MATLABDetector.detectInstallations()
                            } label: {
                                Label("Rescan Installations", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                settingsSection("Storage", systemImage: "externaldrive") {
                    settingsRow(
                        title: "Jobs Folder",
                        subtitle: "Where job metadata and logs are stored."
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
                            TextField("Path", text: $settings.dataDirectory)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: pathFieldWidth)

                            HStack(spacing: 8) {
                                Button("Browse...") {
                                    browseDataDirectory()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.dataDirectory)
                                } label: {
                                    Label("Reveal", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                settingsSection("Alerts", systemImage: "bell.badge") {
                    settingsRow(
                        title: "OS Notifications",
                        subtitle: "Show banners when tasks complete or fail."
                    ) {
                        Toggle("Enabled", isOn: $settings.notificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    settingsRow(
                        title: "Recent Limit",
                        subtitle: "Maximum terminal jobs to surface in quick lists."
                    ) {
                        TextField("", value: $settings.maxRecentJobs, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: shortFieldWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

    private var advancedPane: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection("Network", systemImage: "network") {
                    settingsRow(
                        title: "Auto-start API Server",
                        subtitle: "Launch the local HTTP server when the app starts."
                    ) {
                        Toggle("Enabled", isOn: $settings.autoStartHTTPServer)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    settingsRow(
                        title: "API Port",
                        subtitle: "Listening port for local API requests."
                    ) {
                        TextField("52698", value: $settings.httpPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: shortFieldWidth)
                    }
                }

                settingsSection("Service Health", systemImage: "waveform.path.ecg") {
                    settingsRow(
                        title: "HTTP Listener",
                        subtitle: "State of the in-app server binding on port \(settings.httpPort)."
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            statusBadge(for: listenerPresentation)

                            if let diagnostic = serviceManager.httpDiagnostic {
                                Text(diagnostic)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: controlColumnWidth, alignment: .trailing)
                            }
                        }
                    }

                    settingsRow(
                        title: "Endpoint Probe",
                        subtitle: "Checks GET /api/v1/health through localhost."
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            statusBadge(for: probePresentation)

                            if let lastCheck = serviceManager.lastProbeDate {
                                Text("Last check: \(lastCheck.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    settingsRow(
                        title: "Actions",
                        subtitle: "Use restart when startup fails due to port conflicts or duplicate app instances."
                    ) {
                        HStack(spacing: 8) {
                            Button {
                                serviceManager.probeNow()
                            } label: {
                                Label("Check Now", systemImage: "heart.text.square")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                serviceManager.restartHTTPServer()
                            } label: {
                                Label("Restart HTTP", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button(serviceManager.isHTTPRunning ? "Stop" : "Start") {
                                if serviceManager.isHTTPRunning {
                                    serviceManager.stopHTTPServer()
                                } else {
                                    serviceManager.startHTTPServer()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                settingsSection("CLI Integration", systemImage: "terminal") {
                    settingsRow(
                        title: "CLI Status",
                        subtitle: "Create a shell command for mlm so terminal tools can call it directly."
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            statusBadge(for: cliPresentation)

                            Text(serviceManager.cliMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: controlColumnWidth, alignment: .trailing)

                            Text("Link: \(serviceManager.cliLinkPath)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: controlColumnWidth, alignment: .trailing)
                        }
                    }

                    settingsRow(
                        title: "Actions",
                        subtitle: "Install or refresh the symlink at the recommended PATH location."
                    ) {
                        HStack(spacing: 8) {
                            Button {
                                serviceManager.installOrUpdateCLI()
                            } label: {
                                Label("Install / Update Link", systemImage: "link.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                serviceManager.refreshCLIStatus()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let pathWarning = serviceManager.cliPathWarning {
                        Text(pathWarning)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                settingsSection("Monitoring", systemImage: "clock.arrow.circlepath") {
                    settingsRow(
                        title: "Heartbeat Interval",
                        subtitle: "How often the launcher writes heartbeat markers."
                    ) {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.heartbeatIntervalSeconds, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: shortFieldWidth)
                            Text("sec")
                                .foregroundStyle(.secondary)
                        }
                    }

                    settingsRow(
                        title: "Stale Threshold",
                        subtitle: "Mark a task stale after this duration without heartbeat."
                    ) {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.heartbeatStaleThresholdSeconds, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: shortFieldWidth)
                            Text("sec")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

    private struct StatusPresentation {
        let title: String
        let icon: String
        let tint: Color
    }

    private var listenerPresentation: StatusPresentation {
        switch serviceManager.listenerState {
        case .running:
            return StatusPresentation(title: "Running", icon: "checkmark.circle.fill", tint: .green)
        case .starting:
            return StatusPresentation(title: "Starting", icon: "hourglass", tint: .orange)
        case .stopped:
            return StatusPresentation(title: "Stopped", icon: "pause.circle.fill", tint: .secondary)
        case .failed:
            return StatusPresentation(title: "Failed", icon: "xmark.octagon.fill", tint: .red)
        }
    }

    private var probePresentation: StatusPresentation {
        switch serviceManager.probeState {
        case .healthy:
            return StatusPresentation(title: "Healthy", icon: "waveform.path.ecg", tint: .green)
        case .idle:
            return StatusPresentation(title: "Not Checked", icon: "questionmark.circle", tint: .secondary)
        case .httpError:
            return StatusPresentation(title: "HTTP Error", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .unexpectedResponse:
            return StatusPresentation(title: "Unexpected Response", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .unreachable:
            return StatusPresentation(title: "Unreachable", icon: "bolt.horizontal.circle.fill", tint: .red)
        }
    }

    private var cliPresentation: StatusPresentation {
        switch serviceManager.cliState {
        case .ready:
            return StatusPresentation(title: "Ready", icon: "checkmark.circle.fill", tint: .green)
        case .missing:
            return StatusPresentation(title: "Not Installed", icon: "link", tint: .secondary)
        case .warning:
            return StatusPresentation(title: "Needs Attention", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .error:
            return StatusPresentation(title: "Error", icon: "xmark.octagon.fill", tint: .red)
        }
    }

    private func statusBadge(for presentation: StatusPresentation) -> some View {
        Label(presentation.title, systemImage: presentation.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(presentation.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(presentation.tint.opacity(0.12), in: Capsule())
    }

    private func settingsSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(title)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.36), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 14, y: 5)
        }
    }

    private func settingsRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            control()
                .controlSize(.regular)
                .frame(maxWidth: controlColumnWidth, alignment: .trailing)
        }
        .frame(minHeight: 42)
    }

    private func saveSettings(previousSettings: AppSettings? = nil, newSettings: AppSettings? = nil) {
        let toSave = newSettings ?? settings
        let oldSettings = previousSettings ?? scheduler.settings
        do {
            try toSave.save()
            scheduler.settings = toSave
            serviceManager.handleSettingsChange(from: oldSettings, to: toSave)
            AppDelegate.applyActivationPolicy(hideDockIcon: toSave.hideDockIcon)
        } catch {
            print("Failed to auto-save settings: \(error)")
        }
    }

    private func browseDataDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Data Directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.dataDirectory = url.path
        }
    }
}
