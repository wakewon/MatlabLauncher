import SwiftUI

// MARK: - Main Window View

struct MainWindowView: View {
    @EnvironmentObject var scheduler: JobScheduler
    @Binding var selectedJobId: UUID?
    @State private var showCreateJob = false
    @State private var filterStatus: JobStatus? = nil
    @State private var searchText = ""
    @State private var isSidebarVisible = true
    @State private var sidebarWidth: CGFloat = 260
    @State private var lastExpandedSidebarWidth: CGFloat = 260
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var isHoveringSidebarHandle = false

    private let sidebarMinWidth: CGFloat = 200
    private let sidebarIdealWidth: CGFloat = 260
    private let sidebarMaxWidth: CGFloat = 280
    private let sidebarSnapThreshold: CGFloat = 120
    private let sidebarHandleWidth: CGFloat = 12
    private let sidebarOuterPadding: CGFloat = 10

    var filteredJobs: [Job] {
        var jobs = scheduler.repository.jobs

        if let filter = filterStatus {
            jobs = jobs.filter { $0.status == filter }
        }

        if !searchText.isEmpty {
            jobs = jobs.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.command.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
            }
        }

        return jobs.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        GeometryReader { proxy in
            let effectiveSidebarWidth = resolvedSidebarWidth(for: proxy.size.width)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    sidebarSurface
                        .frame(width: max(0, effectiveSidebarWidth - sidebarOuterPadding))
                        .frame(maxHeight: .infinity)
                        .padding(.leading, sidebarOuterPadding)
                        .padding(.vertical, sidebarOuterPadding)
                        .opacity(effectiveSidebarWidth > 1 ? 1 : 0)

                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                sidebarResizeHandle(currentSidebarWidth: effectiveSidebarWidth, totalWidth: proxy.size.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Matlab Launcher")
        .searchable(text: $searchText, prompt: "Search tasks")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Label(
                        isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                        systemImage: isSidebarVisible ? "sidebar.left" : "sidebar.right"
                    )
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateJob = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button { setFilterStatus(nil) } label: {
                        menuItemLabel("All", selected: filterStatus == nil)
                    }
                    Divider()
                    Button { setFilterStatus(.running) } label: {
                        menuItemLabel("Running", selected: filterStatus == .running)
                    }
                    Button { setFilterStatus(.queued) } label: {
                        menuItemLabel("Queued", selected: filterStatus == .queued)
                    }
                    Button { setFilterStatus(.succeeded) } label: {
                        menuItemLabel("Succeeded", selected: filterStatus == .succeeded)
                    }
                    Button { setFilterStatus(.failed) } label: {
                        menuItemLabel("Failed", selected: filterStatus == .failed)
                    }
                    Button { setFilterStatus(.canceled) } label: {
                        menuItemLabel("Canceled", selected: filterStatus == .canceled)
                    }
                } label: {
                    Label("Status", systemImage: filterStatus == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }

            ToolbarItem(placement: .automatic) {
                let active = scheduler.repository.activeJobs.count
                if active > 0 {
                    activeJobsIndicator(active)
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    openDataDirectory()
                } label: {
                    Label("Open Data Folder", systemImage: "folder")
                }
            }

            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showCreateJob) {
            CreateJobView()
                .environmentObject(scheduler)
        }
        .onAppear {
            sidebarWidth = sidebarIdealWidth
            lastExpandedSidebarWidth = sidebarIdealWidth
            reconcileSelectionWithFilteredJobs()
        }
        .onChange(of: filteredJobs.map(\.id)) { _, _ in
            reconcileSelectionWithFilteredJobs()
        }
        .onDisappear {
            guard isHoveringSidebarHandle else { return }
            NSCursor.pop()
            isHoveringSidebarHandle = false
        }
        .animation(dragStartSidebarWidth == nil ? .easeInOut(duration: 0.18) : nil, value: isSidebarVisible)
        .animation(dragStartSidebarWidth == nil ? .easeInOut(duration: 0.18) : nil, value: sidebarWidth)
    }

    private func reconcileSelectionWithFilteredJobs() {
        let visibleIds = filteredJobs.map(\.id)
        guard let selectedJobId else {
            return
        }

        if !visibleIds.contains(selectedJobId) {
            self.selectedJobId = nil
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if filteredJobs.isEmpty {
            ContentUnavailableView {
                Label("No Tasks", systemImage: "tray")
            } description: {
                Text("Submit a MATLAB task to get started.")
            } actions: {
                Button("New Task") {
                    showCreateJob = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: Date(), by: 30)) { context in
                List(filteredJobs, selection: $selectedJobId) { job in
                    JobRowView(
                        job: job,
                        now: context.date,
                        onCancel: { scheduler.cancelJob(id: job.id) },
                        onKill: { scheduler.forceKillJob(id: job.id) },
                        onRetry: { _ = scheduler.retryJob(id: job.id) }
                    )
                    .tag(job.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            if let selectedId = selectedJobId {
                JobDetailView(jobId: selectedId)
                    .environmentObject(scheduler)
                    .id(selectedId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyDetailPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyDetailPlaceholder: some View {
        ContentUnavailableView {
            Label("Select a Task", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Choose a task from the sidebar to inspect logs and metadata.")
        }
    }

    private var sidebarSurface: some View {
        ZStack(alignment: .topLeading) {
            sidebarContent
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, y: 2)
    }

    private func openDataDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: scheduler.settings.jobsDirectory)
    }

    private func activeJobsIndicator(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.blue)
            Text("\(count) running")
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 104)
        .background(Color.blue.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func setFilterStatus(_ status: JobStatus?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            filterStatus = status
        }
    }

    @ViewBuilder
    private func menuItemLabel(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if selected {
                Image(systemName: "checkmark")
            } else {
                Image(systemName: "checkmark")
                    .hidden()
            }
            Text(title)
        }
    }

    private func toggleSidebar() {
        if isSidebarVisible {
            lastExpandedSidebarWidth = max(sidebarWidth, sidebarMinWidth)
            isSidebarVisible = false
            sidebarWidth = 0
        } else {
            sidebarWidth = min(max(lastExpandedSidebarWidth, sidebarMinWidth), sidebarMaxWidth)
            isSidebarVisible = true
        }
    }

    private func resolvedSidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        guard isSidebarVisible else { return 0 }
        let maxWidth = min(sidebarMaxWidth, totalWidth * 0.45)
        return min(max(sidebarWidth, sidebarMinWidth), maxWidth + sidebarOuterPadding)
    }

    @ViewBuilder
    private func sidebarResizeHandle(currentSidebarWidth: CGFloat, totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: sidebarHandleWidth)
            .contentShape(Rectangle())
            .offset(x: max(0, currentSidebarWidth - sidebarHandleWidth / 2))
            .gesture(sidebarDragGesture(totalWidth: totalWidth))
            .allowsHitTesting(isSidebarVisible || dragStartSidebarWidth != nil)
            .onHover(perform: updateResizeCursor)
    }

    private func sidebarDragGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartSidebarWidth == nil {
                    dragStartSidebarWidth = isSidebarVisible ? sidebarWidth : 0
                }

                let startWidth = dragStartSidebarWidth ?? 0
                let maxWidth = min(sidebarMaxWidth, totalWidth * 0.45)
                let proposedWidth = min(max(startWidth + value.translation.width, 0), maxWidth)
                sidebarWidth = proposedWidth

                if proposedWidth > 0 {
                    isSidebarVisible = true
                }
            }
            .onEnded { _ in
                defer { dragStartSidebarWidth = nil }

                if sidebarWidth < sidebarSnapThreshold {
                    isSidebarVisible = false
                    sidebarWidth = 0
                } else {
                    let clampedWidth = min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth)
                    sidebarWidth = clampedWidth
                    lastExpandedSidebarWidth = clampedWidth
                    isSidebarVisible = true
                }
            }
    }

    private func updateResizeCursor(_ isHovering: Bool) {
        guard isHovering != isHoveringSidebarHandle else { return }
        isHoveringSidebarHandle = isHovering

        if isHovering {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }
}
