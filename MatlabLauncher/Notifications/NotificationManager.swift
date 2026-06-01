import Foundation
import UserNotifications

// MARK: - Notification Manager

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    var isAuthorized = false
    var onOpenJob: ((UUID) -> Void)?

    override init() {
        super.init()
    }

    func setup() {
        center.delegate = self
        requestAuthorization()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                if let error = error {
                    print("Notification authorization error: \(error)")
                }
            }
        }
    }

    // MARK: - Send Notifications

    func notifyJobCompleted(_ job: Job) {
        guard isAuthorized else { return }
        sendNotification(
            title: "✅ Task Completed",
            body: "\(job.name) finished successfully (\(job.elapsedTimeFormatted))",
            jobId: job.id,
            categoryId: "JOB_COMPLETED"
        )
    }

    func notifyJobFailed(_ job: Job) {
        guard isAuthorized else { return }
        let errorMsg = job.errorSummary ?? "Unknown error"
        sendNotification(
            title: "❌ Task Failed",
            body: "\(job.name): \(errorMsg)",
            jobId: job.id,
            categoryId: "JOB_FAILED"
        )
    }

    func notifyJobCanceled(_ job: Job) {
        guard isAuthorized else { return }
        sendNotification(
            title: "⏹ Task Canceled",
            body: "\(job.name) was canceled",
            jobId: job.id,
            categoryId: "JOB_CANCELED"
        )
    }

    func notifyJobStale(_ job: Job) {
        guard isAuthorized else { return }
        sendNotification(
            title: "⚠️ Task May Be Stuck",
            body: "\(job.name) has not responded for a while",
            jobId: job.id,
            categoryId: "JOB_STALE"
        )
    }

    // MARK: - Private

    private func sendNotification(title: String, body: String, jobId: UUID, categoryId: String) {
        // Some menu bar activation-policy transitions can drop the current app icon;
        // refresh it right before delivery so Notification Center resolves the right badge.
        AppDelegate.refreshApplicationIcon()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["jobId": jobId.uuidString]
        content.categoryIdentifier = categoryId

        let request = UNNotificationRequest(
            identifier: "\(categoryId)-\(jobId.uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error)")
            }
        }
    }

    func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_JOB",
            title: "Open Details",
            options: .foreground
        )
        let openLogAction = UNNotificationAction(
            identifier: "OPEN_LOG",
            title: "Open Log",
            options: .foreground
        )

        let completedCategory = UNNotificationCategory(
            identifier: "JOB_COMPLETED",
            actions: [openAction, openLogAction],
            intentIdentifiers: []
        )
        let failedCategory = UNNotificationCategory(
            identifier: "JOB_FAILED",
            actions: [openAction, openLogAction],
            intentIdentifiers: []
        )
        let canceledCategory = UNNotificationCategory(
            identifier: "JOB_CANCELED",
            actions: [openAction],
            intentIdentifiers: []
        )
        let staleCategory = UNNotificationCategory(
            identifier: "JOB_STALE",
            actions: [openAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([
            completedCategory, failedCategory, canceledCategory, staleCategory
        ])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let jobIdString = userInfo["jobId"] as? String,
           let jobId = UUID(uuidString: jobIdString) {
            Task { @MainActor in
                onOpenJob?(jobId)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
