import AppKit
import SwiftUI

// MARK: - Job Detail View

struct JobDetailView: View {
    @EnvironmentObject var scheduler: JobScheduler
    let jobId: UUID

    @State private var stdoutLog = LogDisplayState()
    @State private var stderrLog = LogDisplayState()
    @State private var streamLog = LogDisplayState()
    @State private var refreshTimer: Timer?
    @State private var expandedLogs: Set<LogStream> = [.stdout, .stderr]
    @State private var liveLogs: Set<LogStream> = []
    @State private var autoScrollLogs: Set<LogStream> = [.stdout, .stderr]
    @State private var isCompactLayout = true
    @State private var expandedMetadataField: String?

    private let logHeaderControlWidth: CGFloat = 150
    private let initialDisplayedLogBytes: UInt64 = 65_536
    private let maxDisplayedLogBytes: UInt64 = 1_048_576
    private let compactEnterThreshold: CGFloat = 920
    private let regularEnterThreshold: CGFloat = 980
    private let regularMetadataWidth: CGFloat = 400
    private let metadataLabelWidth: CGFloat = 76

    private enum LogStream: String, CaseIterable, Identifiable {
        case stdout
        case stderr
        case stream

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stdout: return "Standard Output"
            case .stderr: return "Standard Error"
            case .stream: return "Stream Output"
            }
        }

        var emptyHint: String {
            switch self {
            case .stdout: return "No standard output yet..."
            case .stderr: return "No standard error yet..."
            case .stream: return "No stream output yet..."
            }
        }
    }

    private struct LogDisplayState: Equatable {
        var snapshot: LogFileSnapshot = .empty
        var requestedBytes: UInt64 = 65_536
        var isLoading = false

        var content: String { snapshot.content }
    }

    private var job: Job? {
        scheduler.repository.getJob(id: jobId)
    }

    var body: some View {
        if let job = job {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    header(job)

                    Divider()

                    if isCompactLayout {
                        compactContent(job)
                    } else {
                        regularContent(job)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    updateLayoutMode(for: proxy.size.width, force: true)
                    configureLiveMode(for: job)
                    refreshLogs(force: true)
                    startAutoRefresh(job)
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    updateLayoutMode(for: newWidth)
                }
                .onChange(of: jobId) { _, _ in
                    handleJobSelectionChange()
                }
                .onDisappear {
                    refreshTimer?.invalidate()
                }
            }
        } else {
            ContentUnavailableView("Job Not Found", systemImage: "questionmark.circle", description: Text("The requested job could not be found."))
        }
    }

    @ViewBuilder
    private func regularContent(_ job: Job) -> some View {
        HStack(spacing: 0) {
            metadataPanel(job)
                .frame(width: regularMetadataWidth)

            Divider()

            logsPane
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func compactContent(_ job: Job) -> some View {
        VSplitView {
            metadataPanel(job)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 120)

            logsPane
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var logsPane: some View {
        VStack(spacing: 0) {
            logsToolbar

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(LogStream.allCases) { stream in
                        logSection(stream)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ job: Job) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.status.sfSymbol)
                .font(.title3)
                .foregroundStyle(statusColor(job.status))

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(job.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            StatusBadge(status: job.status)

            if job.status.isActive {
                Button("Cancel") {
                    scheduler.cancelJob(id: job.id)
                }
                .buttonStyle(.bordered)

                Button("Force Kill", role: .destructive) {
                    scheduler.forceKillJob(id: job.id)
                }
                .buttonStyle(.bordered)
            } else if job.status == .failed || job.status == .forceKilled {
                Button("Retry") {
                    _ = scheduler.retryJob(id: job.id)
                }
                .buttonStyle(.bordered)
            }

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: job.jobDirectory)
            } label: {
                Label("Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }

    // MARK: - Metadata Panel

    @ViewBuilder
    private func metadataPanel(_ job: Job) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                metadataSection("Status") {
                    metadataValue("State") {
                        StatusBadge(status: job.status)
                    }

                    if let pid = job.pid {
                        metadataValue("PID", value: "\(pid)")
                    }

                    if let exitCode = job.exitCode {
                        metadataValue("Exit Code", value: "\(exitCode)")
                    }
                }

                metadataSection("Timing") {
                    metadataValue("Created", value: formatDate(job.createdAt))
                    if let start = job.startedAt {
                        metadataValue("Started", value: formatDate(start))
                    }
                    if let finished = job.finishedAt {
                        metadataValue("Finished", value: formatDate(finished))
                    }
                    metadataValue("Duration", value: job.elapsedTimeFormatted)
                    if let heartbeat = job.lastHeartbeat {
                        metadataValue("Heartbeat", value: formatDate(heartbeat))
                    }
                }

                metadataSection("Configuration") {
                    inspectableMetadataValue("MATLAB", value: job.matlabPath, monospaced: true)
                    inspectableMetadataValue("Directory", value: job.workingDirectory, monospaced: true)
                    inspectableMetadataValue("Command", value: job.command, monospaced: true)
                    if !job.extraArgs.isEmpty {
                        inspectableMetadataValue("Arguments", value: job.extraArgs.joined(separator: " "), monospaced: true)
                    }
                }

                if let result = job.resultSummary {
                    metadataSection("Result") {
                        metadataValue("Summary", value: result)
                    }
                }

                if let error = job.errorSummary {
                    metadataSection("Error") {
                        inspectableMetadataValue("Summary", value: error)
                    }
                }

                metadataSection("Paths") {
                    inspectableMetadataValue("Job", value: job.jobDirectory, monospaced: true, revealPath: job.jobDirectory)
                    inspectableMetadataValue("Stdout", value: job.stdoutLogPath, monospaced: true, revealPath: job.stdoutLogPath)
                    inspectableMetadataValue("Stderr", value: job.stderrLogPath, monospaced: true, revealPath: job.stderrLogPath)
                    inspectableMetadataValue("Stream", value: job.stdoutLogPath + ".stream", monospaced: true, revealPath: job.stdoutLogPath + ".stream")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metadataSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline.weight(.semibold))
        }
    }

    @ViewBuilder
    private func metadataValue(_ title: String, value: String, monospaced: Bool = false) -> some View {
        metadataValue(title) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func metadataValue<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: metadataLabelWidth, alignment: .leading)

            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inspectableMetadataValue(
        _ title: String,
        value: String,
        monospaced: Bool = false,
        revealPath: String? = nil
    ) -> some View {
        let fieldKey = "\(title)-\(value.hashValue)"
        let isPresented = Binding(
            get: { expandedMetadataField == fieldKey },
            set: { newValue in
                if newValue {
                    expandedMetadataField = fieldKey
                } else if expandedMetadataField == fieldKey {
                    expandedMetadataField = nil
                }
            }
        )

        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: metadataLabelWidth, alignment: .leading)

            Button {
                expandedMetadataField = (expandedMetadataField == fieldKey) ? nil : fieldKey
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(monospaced ? .caption.monospaced() : .caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .help("Click to inspect and copy")
            .popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                metadataInspectorPopover(title: title, value: value, monospaced: monospaced, revealPath: revealPath)
            }
        }
    }

    private func metadataInspectorPopover(
        title: String,
        value: String,
        monospaced: Bool,
        revealPath: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))

                    Text("\(value.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let revealPath {
                    Button {
                        revealFileOrDirectory(revealPath)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    copyToPasteboard(value)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(value)
                    .font(monospaced ? .caption.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minWidth: 540, idealWidth: 680, maxWidth: 780, minHeight: 110, idealHeight: 160, maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )
        }
        .padding(14)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealFileOrDirectory(_ path: String) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    private func updateLayoutMode(for width: CGFloat, force: Bool = false) {
        let nextMode: Bool

        if force {
            nextMode = width < regularEnterThreshold
        } else if isCompactLayout {
            nextMode = width < regularEnterThreshold
        } else {
            nextMode = width < compactEnterThreshold
        }

        guard nextMode != isCompactLayout else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            isCompactLayout = nextMode
        }
    }

    // MARK: - Log Panel

    private var logsToolbar: some View {
        HStack(spacing: 12) {
            Text("Logs")
                .font(.headline.weight(.semibold))

            Spacer(minLength: 8)

            Button(expandedLogs.count == LogStream.allCases.count ? "Collapse All" : "Expand All") {
                if expandedLogs.count == LogStream.allCases.count {
                    expandedLogs.removeAll()
                    liveLogs.removeAll()
                } else {
                    expandedLogs = Set(LogStream.allCases)
                    refreshLogs(force: true)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline.weight(.medium))

            Button {
                refreshLogs(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func logSection(_ stream: LogStream) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                logSectionHeader(stream)

                if expandedLogs.contains(stream) {
                    Divider()

                    VStack(spacing: 0) {
                        let state = logState(for: stream)
                        LogTextView(
                            content: state.content.isEmpty ? stream.emptyHint : state.content,
                            autoScroll: autoScrollLogs.contains(stream)
                        )
                        .frame(minHeight: 180, maxHeight: 520)

                        if state.snapshot.isTruncated || state.isLoading {
                            Divider()

                            HStack(spacing: 10) {
                                if state.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading log window...")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Showing last \(formatByteCount(state.snapshot.displayedBytes)) of \(formatByteCount(state.snapshot.fileSize))")
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    loadMoreLog(stream)
                                } label: {
                                    Label("Load More", systemImage: "arrow.up.to.line.compact")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(state.isLoading || !state.snapshot.isTruncated)

                                Button {
                                    openLogFile(stream)
                                } label: {
                                    Label("Open Full Log", systemImage: "doc.text")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!logFileExists(stream))
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private func logSectionHeader(_ stream: LogStream) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleExpanded(stream)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedLogs.contains(stream) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .center)

                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: stream))
                        Text(stream.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.subheadline.weight(.semibold))
                    .layoutPriority(1)

                    statusPill(for: stream)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            logHeaderControls(stream)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 34)
    }

    private func logHeaderControls(_ stream: LogStream) -> some View {
        let isExpanded = expandedLogs.contains(stream)
        let isLive = liveLogs.contains(stream)
        let isFollowing = autoScrollLogs.contains(stream)

        return HStack(spacing: 4) {
            controlIconButton(
                systemImage: isLive ? "pause.fill" : "play.fill",
                active: isLive,
                help: isLive ? "Pause live refresh" : "Resume live refresh"
            ) {
                if isLive {
                    liveLogs.remove(stream)
                } else {
                    liveLogs.insert(stream)
                    refreshLog(stream, resetWindow: false)
                }
            }
            .disabled(!isExpanded)

            controlIconButton(
                systemImage: isFollowing ? "arrow.down.to.line" : "arrow.down",
                active: isFollowing,
                help: isFollowing ? "Following newest output" : "Enable follow"
            ) {
                if isFollowing {
                    autoScrollLogs.remove(stream)
                } else {
                    autoScrollLogs.insert(stream)
                }
            }
            .disabled(!isExpanded)

            Button {
                refreshLog(stream, resetWindow: false)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Refresh this log")

            Button {
                openLogFile(stream)
            } label: {
                Image(systemName: "doc.text")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Open full log")
            .disabled(!isExpanded || !logFileExists(stream))
        }
        .opacity(isExpanded ? 1 : 0.62)
        .frame(width: logHeaderControlWidth, alignment: .trailing)
    }

    private func controlIconButton(
        systemImage: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 16, height: 16)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active
                              ? Color.accentColor.opacity(0.16)
                              : Color(nsColor: .separatorColor).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconName(for stream: LogStream) -> String {
        switch stream {
        case .stdout: return "terminal"
        case .stderr: return "exclamationmark.bubble"
        case .stream: return "dot.radiowaves.left.and.right"
        }
    }

    private func statusPill(for stream: LogStream) -> some View {
        let isLive = liveLogs.contains(stream)
        return Text(isLive ? "Live" : "Paused")
            .font(.caption2.weight(.medium))
            .foregroundStyle(isLive ? .blue : .secondary)
            .frame(width: 50)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill((isLive ? Color.blue : Color.secondary).opacity(0.15))
            )
    }

    private func toggleExpanded(_ stream: LogStream) {
        if expandedLogs.contains(stream) {
            expandedLogs.remove(stream)
            liveLogs.remove(stream)
        } else {
            expandedLogs.insert(stream)
            refreshLog(stream, resetWindow: false)
        }
    }

    // MARK: - Helpers

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

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func refreshLogs(force: Bool = false) {
        guard job != nil else { return }

        for stream in LogStream.allCases where shouldRefresh(stream, force: force) {
            refreshLog(stream, resetWindow: force)
        }
    }

    private func handleJobSelectionChange() {
        // Avoid showing stale content from the previously selected job.
        stdoutLog = LogDisplayState(requestedBytes: initialDisplayedLogBytes)
        stderrLog = LogDisplayState(requestedBytes: initialDisplayedLogBytes)
        streamLog = LogDisplayState(requestedBytes: initialDisplayedLogBytes)
        expandedMetadataField = nil

        refreshTimer?.invalidate()

        if let currentJob = job {
            configureLiveMode(for: currentJob)
            refreshLogs(force: true)
            startAutoRefresh(currentJob)
        }
    }

    private func shouldRefresh(_ stream: LogStream, force: Bool) -> Bool {
        if force { return true }
        return expandedLogs.contains(stream) && liveLogs.contains(stream)
    }

    private func refreshLog(_ stream: LogStream, resetWindow: Bool) {
        guard let job = job else { return }
        let requestedBytes = resetWindow ? initialDisplayedLogBytes : logState(for: stream).requestedBytes
        setLogState(for: stream) { state in
            state.requestedBytes = requestedBytes
            state.isLoading = true
        }

        let currentJobId = job.id
        let isActive = job.status.isActive
        let stdoutPath = job.stdoutLogPath
        let stderrPath = job.stderrLogPath
        let streamPath = job.stdoutLogPath + ".stream"

        Task.detached(priority: .utility) {
            let snapshot: LogFileSnapshot
            switch stream {
            case .stdout:
                let primary = JobRepository.readLogTail(atPath: stdoutPath, maxBytes: requestedBytes)
                let streamSnapshot = JobRepository.readLogTail(atPath: streamPath, maxBytes: requestedBytes)
                snapshot = Self.resolveStdoutSnapshot(primary: primary, stream: streamSnapshot, isActive: isActive)
            case .stderr:
                snapshot = JobRepository.readLogTail(atPath: stderrPath, maxBytes: requestedBytes)
            case .stream:
                snapshot = JobRepository.readLogTail(atPath: streamPath, maxBytes: requestedBytes)
            }

            await MainActor.run {
                guard self.jobId == currentJobId else { return }
                self.setLogState(for: stream) { state in
                    state.snapshot = snapshot
                    state.requestedBytes = requestedBytes
                    state.isLoading = false
                }
            }
        }
    }

    private func loadMoreLog(_ stream: LogStream) {
        let currentBytes = logState(for: stream).requestedBytes
        let nextBytes = min(max(currentBytes * 2, initialDisplayedLogBytes), maxDisplayedLogBytes)
        setLogState(for: stream) { state in
            state.requestedBytes = nextBytes
        }
        refreshLog(stream, resetWindow: false)
    }

    private func logFilePath(for stream: LogStream) -> String? {
        guard let job else { return nil }

        switch stream {
        case .stdout:
            if FileManager.default.fileExists(atPath: job.stdoutLogPath) {
                return job.stdoutLogPath
            }
            let streamPath = job.stdoutLogPath + ".stream"
            return FileManager.default.fileExists(atPath: streamPath) ? streamPath : job.stdoutLogPath
        case .stderr:
            return job.stderrLogPath
        case .stream:
            return job.stdoutLogPath + ".stream"
        }
    }

    private func logFileExists(_ stream: LogStream) -> Bool {
        guard let path = logFilePath(for: stream) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func openLogFile(_ stream: LogStream) {
        guard let path = logFilePath(for: stream), FileManager.default.fileExists(atPath: path) else {
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    nonisolated private static func resolveStdoutSnapshot(
        primary: LogFileSnapshot,
        stream: LogFileSnapshot,
        isActive: Bool
    ) -> LogFileSnapshot {
        let primaryTrimmed = primary.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamTrimmed = stream.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if primaryTrimmed.isEmpty { return stream }
        if streamTrimmed.isEmpty { return primary }

        if primaryTrimmed.contains(streamTrimmed) {
            return primary
        }

        if streamTrimmed.contains(primaryTrimmed) {
            return stream
        }

        if isActive {
            return stream
        }

        return primary.content.count >= stream.content.count ? primary : stream
    }

    private func startAutoRefresh(_ job: Job) {
        guard job.status.isActive else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                refreshLogs()
            }
        }
    }

    private func configureLiveMode(for job: Job) {
        if job.status.isActive {
            liveLogs = [.stdout, .stderr]
        } else {
            liveLogs.removeAll()
        }
    }

    private func logState(for stream: LogStream) -> LogDisplayState {
        switch stream {
        case .stdout: return stdoutLog
        case .stderr: return stderrLog
        case .stream: return streamLog
        }
    }

    private func setLogState(
        for stream: LogStream,
        update: (inout LogDisplayState) -> Void
    ) {
        switch stream {
        case .stdout:
            update(&stdoutLog)
        case .stderr:
            update(&stderrLog)
        case .stream:
            update(&streamLog)
        }
    }

    private func formatByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct LogTextView: NSViewRepresentable {
    let content: String
    let autoScroll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.lastContent != content else { return }
        context.coordinator.lastContent = content
        context.coordinator.textView?.string = content

        if autoScroll {
            context.coordinator.textView?.scrollToEndOfDocument(nil)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastContent = ""
    }
}
