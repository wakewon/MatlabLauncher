import Foundation

// MARK: - Heartbeat Monitor

/// Periodically checks process liveness and updates heartbeat files
@MainActor
final class HeartbeatMonitor {
    private var timer: Timer?
    private let interval: TimeInterval
    private let staleThreshold: TimeInterval
    private let processManager: ProcessManager
    private weak var repository: JobRepository?
    var onJobStale: ((Job) -> Void)?
    var onJobDied: ((Job) -> Void)?

    init(
        interval: TimeInterval = 10,
        staleThreshold: TimeInterval = 60,
        processManager: ProcessManager,
        repository: JobRepository
    ) {
        self.interval = interval
        self.staleThreshold = staleThreshold
        self.processManager = processManager
        self.repository = repository
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard let repository = repository else { return }

        for job in repository.activeJobs {
            guard let pid = job.pid, job.status == .running || job.status == .stale else {
                continue
            }

            let isAlive = processManager.isProcessAlive(pid: pid)

            if isAlive {
                // Process is alive — update heartbeat
                repository.updateHeartbeat(for: job)
                var updatedJob = job
                updatedJob.lastHeartbeat = Date()

                // Check if previously stale — it recovered
                if job.status == .stale {
                    updatedJob.status = .running
                    repository.updateJob(updatedJob)
                } else {
                    // Just update heartbeat timestamp in memory
                    repository.updateJob(updatedJob)
                }
            } else {
                // Process is dead but we thought it was running
                onJobDied?(job)
            }
        }
    }
}
