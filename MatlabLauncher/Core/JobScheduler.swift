import Foundation
import Combine

// MARK: - Job Scheduler

/// Central coordinator: accepts job submissions, drives the state machine,
/// manages execution lifecycle, and emits events for UI/notification layers.
@MainActor
final class JobScheduler: ObservableObject {
    let repository: JobRepository
    let processManager: ProcessManager
    let heartbeatMonitor: HeartbeatMonitor
    @Published var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    var onJobCompleted: ((Job) -> Void)?
    var onJobFailed: ((Job) -> Void)?
    var onJobCanceled: ((Job) -> Void)?
    var onJobStale: ((Job) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        self.repository = JobRepository(baseDirectory: settings.jobsDirectory)
        self.processManager = ProcessManager()
        self.heartbeatMonitor = HeartbeatMonitor(
            interval: TimeInterval(settings.heartbeatIntervalSeconds),
            staleThreshold: TimeInterval(settings.heartbeatStaleThresholdSeconds),
            processManager: processManager,
            repository: repository
        )

        // Setup heartbeat callbacks
        heartbeatMonitor.onJobDied = { [weak self] job in
            Task { @MainActor in
                self?.handleProcessDied(job)
            }
        }
        heartbeatMonitor.onJobStale = { [weak self] job in
            Task { @MainActor in
                self?.handleJobStale(job)
            }
        }

        // Forward repository changes so views observing scheduler refresh reliably.
        repository.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        // Load existing jobs from disk
        repository.loadAllJobs()

        // Recover running jobs
        recoverJobs()

        // Start heartbeat monitoring
        heartbeatMonitor.start()
    }

    func stop() {
        heartbeatMonitor.stop()
    }

    // MARK: - Job Submission

    func submitJob(_ submission: JobSubmission) -> Job {
        let job = repository.createJob(from: submission, settings: settings)
        startJob(job)
        return job
    }

    // MARK: - Job Control

    func cancelJob(id: UUID) {
        guard var job = repository.getJob(id: id) else { return }
        guard job.status.isActive else { return }

        if job.status == .queued {
            // Not started yet — just cancel
            job.status = .canceled
            job.finishedAt = Date()
            repository.updateJob(job)
            onJobCanceled?(job)
            return
        }

        // Write cancel flag
        repository.writeCancelFlag(for: job)

        // Send SIGTERM
        processManager.terminate(jobId: id)

        // Schedule force kill if process doesn't exit
        let killDelay = TimeInterval(settings.cancelGracePeriodSeconds)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(killDelay * 1_000_000_000))
            if let currentJob = self.repository.getJob(id: id),
               currentJob.status == .running || currentJob.status == .stale {
                // Still running after grace period — force kill
                self.forceKillJob(id: id)
            }
        }
    }

    func forceKillJob(id: UUID) {
        guard var job = repository.getJob(id: id) else { return }
        guard job.status.isActive else { return }

        processManager.forceKill(jobId: id)

        job.status = .forceKilled
        job.finishedAt = Date()
        job.exitCode = -9
        job.errorSummary = "Force killed by user"
        repository.updateJob(job)
        repository.writeError(
            for: job,
            exitCode: -9,
            message: "Force killed by user",
            lastStderr: repository.tailLog(for: job, stream: "stderr", lines: 20)
        )
        processManager.cleanup(jobId: id)
    }

    // MARK: - Job Retry

    func retryJob(id: UUID) -> Job? {
        guard let originalJob = repository.getJob(id: id),
              originalJob.status.isTerminal else { return nil }

        let submission = JobSubmission(
            name: originalJob.name + " (retry)",
            matlabPath: originalJob.matlabPath,
            workingDirectory: originalJob.workingDirectory,
            command: originalJob.command,
            tags: originalJob.tags,
            extraArgs: originalJob.extraArgs,
            environment: originalJob.environment
        )

        var newJob = repository.createJob(from: submission, settings: settings)
        newJob.retryOf = originalJob.id
        repository.updateJob(newJob)
        startJob(newJob)
        return newJob
    }

    // MARK: - Private: Job Execution

    private func startJob(_ job: Job) {
        var mutableJob = job
        mutableJob.status = .starting
        repository.updateJob(mutableJob)

        // Capture everything we need for the detached task
        let jobId = job.id
        let pm = processManager

        Task.detached { [pm] in
            do {
                let (_, pid) = try pm.launchProcess(for: mutableJob)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard var runningJob = self.repository.getJob(id: jobId) else { return }
                    runningJob.status = .running
                    runningJob.pid = pid
                    runningJob.startedAt = Date()
                    runningJob.lastHeartbeat = Date()
                    self.repository.updateJob(runningJob)
                    self.repository.updateHeartbeat(for: runningJob)
                }

                // Wait for completion
                pm.waitForCompletion(jobId: jobId) { exitCode in
                    Task { @MainActor [weak self] in
                        self?.handleProcessExit(jobId: jobId, exitCode: exitCode)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard var failedJob = self.repository.getJob(id: jobId) else { return }
                    failedJob.status = .failed
                    failedJob.finishedAt = Date()
                    failedJob.errorSummary = "Failed to start: \(error.localizedDescription)"
                    self.repository.updateJob(failedJob)
                    self.repository.writeError(
                        for: failedJob,
                        exitCode: -1,
                        message: error.localizedDescription,
                        lastStderr: nil
                    )
                    self.onJobFailed?(failedJob)
                }
            }
        }
    }

    private func handleProcessExit(jobId: UUID, exitCode: Int32) {
        guard var job = repository.getJob(id: jobId) else { return }
        guard !job.status.isTerminal else { return } // Already handled (e.g., force killed)

        job.finishedAt = Date()
        job.exitCode = exitCode

        if repository.cancelFlagExists(for: job) {
            job.status = .canceled
            job.resultSummary = "Canceled by user"
            repository.updateJob(job)
            onJobCanceled?(job)
        } else if exitCode == 0 {
            job.status = .succeeded
            job.resultSummary = "Completed successfully"
            repository.updateJob(job)
            repository.writeResult(for: job, exitCode: 0, summary: "Completed successfully")
            onJobCompleted?(job)
        } else {
            job.status = .failed
            let lastStderr = repository.tailLog(for: job, stream: "stderr", lines: 20)
            let lastStdout = repository.tailLog(for: job, stream: "stdout", lines: 10)
            job.errorSummary = "Exit code \(exitCode)"
            if !lastStderr.isEmpty {
                job.errorSummary = lastStderr.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? job.errorSummary
            } else if !lastStdout.isEmpty {
                // Sometimes MATLAB writes errors to stdout via -logfile
                let lines = lastStdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
                job.errorSummary = lines.last ?? job.errorSummary
            }
            repository.updateJob(job)
            repository.writeError(
                for: job,
                exitCode: exitCode,
                message: job.errorSummary ?? "Unknown error",
                lastStderr: lastStderr
            )
            onJobFailed?(job)
        }

        processManager.cleanup(jobId: jobId)
    }

    private func handleProcessDied(_ job: Job) {
        // Process died unexpectedly — check exit status
        guard var mutableJob = repository.getJob(id: job.id),
              !mutableJob.status.isTerminal else { return }

        // Try to get exit code from Process object
        if let process = processManager.getProcess(for: job.id) {
            let exitCode = process.terminationStatus
            handleProcessExit(jobId: job.id, exitCode: exitCode)
        } else {
            mutableJob.status = .failed
            mutableJob.finishedAt = Date()
            mutableJob.exitCode = -1
            mutableJob.errorSummary = "Process terminated unexpectedly"
            repository.updateJob(mutableJob)
            repository.writeError(
                for: mutableJob,
                exitCode: -1,
                message: "Process terminated unexpectedly",
                lastStderr: repository.tailLog(for: mutableJob, stream: "stderr", lines: 20)
            )
            onJobFailed?(mutableJob)
            processManager.cleanup(jobId: job.id)
        }
    }

    private func handleJobStale(_ job: Job) {
        guard var mutableJob = repository.getJob(id: job.id) else { return }
        mutableJob.status = .stale
        repository.updateJob(mutableJob)
        onJobStale?(mutableJob)
    }

    // MARK: - Recovery

    private func recoverJobs() {
        for job in repository.jobs where job.status.isActive {
            guard let pid = job.pid else {
                // Job was queued/starting but never got a PID — mark as failed
                var mutableJob = job
                mutableJob.status = .failed
                mutableJob.finishedAt = Date()
                mutableJob.errorSummary = "App restarted before job could start"
                repository.updateJob(mutableJob)
                continue
            }

            if processManager.isProcessAlive(pid: pid) {
                // Process is still running — we can't re-attach to it with Process object,
                // but we can monitor it via PID
                var mutableJob = job
                mutableJob.lastHeartbeat = Date()
                mutableJob.status = .running
                repository.updateJob(mutableJob)
                repository.updateHeartbeat(for: mutableJob)

                // Start monitoring this PID
                monitorExternalPID(jobId: job.id, pid: pid)
            } else {
                // Process is dead — mark as failed (we don't know the exit code)
                var mutableJob = job
                mutableJob.status = .failed
                mutableJob.finishedAt = Date()
                mutableJob.errorSummary = "Process died while app was not running"
                repository.updateJob(mutableJob)
                repository.writeError(
                    for: mutableJob,
                    exitCode: -1,
                    message: "Process died while app was not running",
                    lastStderr: repository.tailLog(for: mutableJob, stream: "stderr", lines: 20)
                )
            }
        }
    }

    /// Monitor an external PID that we can't attach a Process object to
    private func monitorExternalPID(jobId: UUID, pid: Int32) {
        let pm = processManager
        Task.detached { [pm] in
            // Poll until process exits
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                if !pm.isProcessAlive(pid: pid) {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        guard var job = self.repository.getJob(id: jobId),
                              !job.status.isTerminal else { return }
                        // We can't get exit code for external PIDs reliably
                        // Check if result.json was written by the process
                        let resultPath = job.resultJSONPath
                        if FileManager.default.fileExists(atPath: resultPath) {
                            job.status = .succeeded
                            job.resultSummary = "Completed (recovered after app restart)"
                        } else {
                            job.status = .failed
                            job.errorSummary = "Process exited (recovered after app restart)"
                        }
                        job.finishedAt = Date()
                        self.repository.updateJob(job)
                    }
                    break
                }
            }
        }
    }
}
