import SwiftUI

// MARK: - Status Badge

struct StatusBadge: View {
    let status: JobStatus

    private var color: Color {
        switch status {
        case .queued: return .secondary
        case .starting, .running: return .blue
        case .succeeded: return .green
        case .failed, .forceKilled: return .red
        case .canceled: return .orange
        case .stale: return .yellow
        }
    }

    var body: some View {
        Label(status.displayName, systemImage: status.sfSymbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
    }
}

// MARK: - Job Row View (for list)

struct JobRowView: View {
    let job: Job
    let now: Date
    let onCancel: () -> Void
    let onKill: () -> Void
    let onRetry: () -> Void

    var body: some View {
        row
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                rowActions
            }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                titleLine

                Text(job.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(statusCaption(now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: some View {
        titleRow
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(job.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer(minLength: 8)

            Text(job.elapsedTimeFormatted)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowActions: some View {
        if job.status.isActive {
            Button("Cancel", role: .destructive) { onCancel() }
            Button("Force Kill", role: .destructive) { onKill() }
        } else if job.status == .failed || job.status == .forceKilled {
            Button("Retry") { onRetry() }
        }
    }

    private func statusCaption(now: Date) -> String {
        if let when = job.status.isActive ? job.startedAt : job.finishedAt {
            let formatter = RelativeDateTimeFormatter()
            let relative = formatter.localizedString(for: when, relativeTo: now)
            return job.status.isActive
                ? "Started \(relative)"
                : "Finished \(relative)"
        }
        return job.status.displayName
    }

    private var statusColor: Color {
        switch job.status {
        case .queued: return .secondary
        case .starting, .running: return .blue
        case .succeeded: return .green
        case .failed, .forceKilled: return .red
        case .canceled: return .orange
        case .stale: return .yellow
        }
    }
}

// MARK: - Log Viewer

struct LogViewer: View {
    let content: String
    let title: String
    @State private var autoScroll = true

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(content.isEmpty ? "No output yet..." : content)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                            .id("logBottom")
                    }
                    .onChange(of: content) { _, _ in
                        if autoScroll {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
