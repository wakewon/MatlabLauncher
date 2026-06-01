import SwiftUI
import KeyboardShortcuts

@main
struct MatlabLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var scheduler: JobScheduler
    @StateObject private var serviceManager: ServiceManager
    @StateObject private var notificationManager = NotificationManager.shared
    @State private var selectedJobId: UUID?
    @State private var showMainWindow = false
    @Environment(\.openWindow) private var openWindow

    init() {
        let settings = AppSettings.load()
        let sched = JobScheduler(settings: settings)
        let services = ServiceManager(scheduler: sched)
        _scheduler = StateObject(wrappedValue: sched)
        _serviceManager = StateObject(wrappedValue: services)

        // Schedule setup for after app finishes launching
        let notifMgr = NotificationManager.shared
        DispatchQueue.main.async {
            // Start scheduler (loads jobs, starts heartbeat)
            sched.start()

            // Wire up notification callbacks
            notifMgr.setup()
            notifMgr.registerCategories()

            sched.onJobCompleted = { job in
                NotificationManager.shared.notifyJobCompleted(job)
            }
            sched.onJobFailed = { job in
                NotificationManager.shared.notifyJobFailed(job)
            }
            sched.onJobCanceled = { job in
                NotificationManager.shared.notifyJobCanceled(job)
            }
            sched.onJobStale = { job in
                NotificationManager.shared.notifyJobStale(job)
            }

            // Bootstrap HTTP service management and health probing.
            services.bootstrap()

            print("[App] Setup complete — \(sched.repository.jobs.count) jobs loaded")
        }
    }

    var body: some Scene {
        // Menu bar
        MenuBarExtra {
            MenuBarView(
                selectedJobId: $selectedJobId,
                showMainWindow: $showMainWindow
            )
            .environmentObject(scheduler)
            .onAppear {
                setupShortcuts()
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        // Main window
        Window("Matlab Launcher", id: "main-window") {
            MainWindowView(selectedJobId: $selectedJobId)
                .environmentObject(scheduler)
                .frame(minWidth: 840, minHeight: 560)
        }
        .defaultSize(width: 1020, height: 700)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(scheduler)
                .environmentObject(serviceManager)
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let activeCount = scheduler.repository.activeJobs.count

        HStack(spacing: 2) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.caption2)
            }
        }
    }
    
    private func setupShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleMainWindow) {
            openWindow(id: "main-window")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    static func refreshApplicationIcon() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }

    @MainActor
    static func applyActivationPolicy(hideDockIcon: Bool) {
        let targetPolicy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }

        // Keep icon consistent after policy transitions (regular <-> accessory).
        refreshApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.load()
        Self.applyActivationPolicy(hideDockIcon: settings.hideDockIcon)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Stay alive as menu bar app
    }
}
