import SwiftUI

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var scheduler: JobScheduler
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedJobId: UUID?
    @Binding var showMainWindow: Bool

    private let panelWidth: CGFloat = 372
    private let actionIconSlotWidth: CGFloat = 16

    var activeJobs: [Job] {
        scheduler.repository.activeJobs
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentJobs: [Job] {
        let terminalJobs = scheduler.repository.recentTerminalJobs(limit: 8)
        if !terminalJobs.isEmpty {
            return terminalJobs
        }

        let activeIds = Set(activeJobs.map(\.id))
        return scheduler.repository.jobs
            .filter { !activeIds.contains($0.id) }
            .sorted {
                let lhs = $0.finishedAt ?? $0.createdAt
                let rhs = $1.finishedAt ?? $1.createdAt
                return lhs > rhs
            }
            .prefix(8)
            .map { $0 }
    }

    private var failedCount: Int {
        scheduler.repository.jobs.filter { $0.status == .failed || $0.status == .forceKilled }.count
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                headerCard

                if !activeJobs.isEmpty {
                    jobsCard(title: "Running", jobs: activeJobs, isRunningSection: true, now: context.date)
                }

                if !recentJobs.isEmpty {
                    jobsCard(title: "Recent", jobs: recentJobs, isRunningSection: false, now: context.date)
                }

                if activeJobs.isEmpty && recentJobs.isEmpty {
                    emptyCard
                }

                actionsCard
            }
            .padding(12)
            .frame(width: panelWidth)
        }
    }

    private var headerCard: some View {
        panelCard {
            HStack(alignment: .firstTextBaseline) {
                Label("Matlab Launcher", systemImage: "m.circle.fill")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(activeJobs.isEmpty ? "Idle" : "\(activeJobs.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metricPill(title: "Running", value: activeJobs.count, color: .blue)
                metricPill(title: "Recent", value: recentJobs.count, color: .secondary)
                metricPill(title: "Failed", value: failedCount, color: .red)
            }
        }
    }

    private var emptyCard: some View {
        panelCard {
            ContentUnavailableView {
                Label("No Tasks", systemImage: "tray")
            } description: {
                Text("Create or run a MATLAB task to populate this panel.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func jobsCard(title: String, jobs: [Job], isRunningSection: Bool, now: Date) -> some View {
        panelCard {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(jobs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(jobs.prefix(4).enumerated()), id: \.offset) { index, job in
                    jobRow(job, isRunningSection: isRunningSection, now: now)

                    if index < min(jobs.count, 4) - 1 {
                        Divider()
                    }
                }
            }

            if jobs.count > 4 {
                Text("+\(jobs.count - 4) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionsCard: some View {
        panelCard {
            LazyVGrid(columns: actionColumns, spacing: 8) {
                actionButton(title: "Main Window", systemImage: "macwindow") {
                    openMainWindow()
                }

                SettingsLink {
                    actionLabel(title: "Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                actionButton(title: "Restart App", systemImage: "arrow.clockwise") {
                    restartApplication()
                }

                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    actionLabel(title: "Quit", systemImage: "xmark.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var actionColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private func jobRow(_ job: Job, isRunningSection: Bool, now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.status.sfSymbol)
                .foregroundStyle(statusColor(job.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .lineLimit(1)

                Text(rowSubtitle(for: job, isRunningSection: isRunningSection, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isRunningSection {
                Menu {
                    Button {
                        openJob(job.id)
                    } label: {
                        Label("Open in Main Window", systemImage: "macwindow")
                    }

                    Button("Cancel", role: .destructive) {
                        scheduler.cancelJob(id: job.id)
                    }

                    Button("Force Kill", role: .destructive) {
                        scheduler.forceKillJob(id: job.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            openJob(job.id)
        }
    }

    private func rowSubtitle(for job: Job, isRunningSection: Bool, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()

        if isRunningSection, let startedAt = job.startedAt {
            let relative = formatter.localizedString(for: startedAt, relativeTo: now)
            return "Started \(relative)  •  \(job.elapsedTimeFormatted)"
        }

        if let finishedAt = job.finishedAt {
            let relative = formatter.localizedString(for: finishedAt, relativeTo: now)
            return "\(job.status.displayName) \(relative)"
        }

        return job.status.displayName
    }

    private func metricPill(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(value)")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func panelCard<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: actionIconSlotWidth, alignment: .leading)

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Color.clear
                .frame(width: actionIconSlotWidth)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .center)
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .starting, .running: return .blue
        case .succeeded: return .green
        case .failed, .forceKilled: return .red
        case .canceled: return .orange
        case .stale: return .yellow
        }
    }

    private func openMainWindow() {
        openWindow(id: "main-window")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openJob(_ id: UUID) {
        selectedJobId = id
        openMainWindow()
    }

    private func restartApplication() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { launchedApp, error in
            if let error {
                print("[MenuBar] Failed to relaunch app: \(error)")
                return
            }

            guard launchedApp != nil else {
                print("[MenuBar] Relaunch returned no app instance")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }
}
