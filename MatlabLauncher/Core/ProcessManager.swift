import Foundation

// MARK: - Process Manager

/// Manages process lifecycle: spawning, monitoring, signaling
final class ProcessManager: @unchecked Sendable {
    private var processes: [UUID: Process] = [:]
    private var stdoutHandles: [UUID: FileHandle] = [:]
    private var stderrHandles: [UUID: FileHandle] = [:]
    private let lock = NSLock()

    // MARK: - Process Spawning

    /// Launch a MATLAB process for the given job
    func launchProcess(for job: Job) throws -> (process: Process, pid: Int32) {
        let process = Process()

        // Configure executable
        process.executableURL = URL(fileURLWithPath: job.matlabPath)

        // Build arguments
        var args: [String] = []
        args.append("-sd")
        args.append(job.workingDirectory)
        args.append("-logfile")
        args.append(job.stdoutLogPath)
        args.append("-batch")
        args.append(job.command)
        args.append(contentsOf: job.extraArgs)
        process.arguments = args

        // Set working directory
        process.currentDirectoryURL = URL(fileURLWithPath: job.workingDirectory)

        // Set environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in job.environment {
            env[key] = value
        }
        process.environment = env

        // Create new process group so we can kill all children
        process.qualityOfService = .userInitiated

        // Setup stderr pipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Setup stdout pipe (forward to file)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // Write stderr to file asynchronously
        let stderrLogURL = URL(fileURLWithPath: job.stderrLogPath)
        FileManager.default.createFile(atPath: job.stderrLogPath, contents: nil)
        let stderrFileHandle = try FileHandle(forWritingTo: stderrLogURL)

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrFileHandle.write(data)
            }
        }

        // Write stdout to file asynchronously
        let stdoutStreamPath = job.stdoutLogPath + ".stream"
        FileManager.default.createFile(atPath: stdoutStreamPath, contents: nil)
        let stdoutStreamURL = URL(fileURLWithPath: stdoutStreamPath)
        let stdoutFileHandle = try FileHandle(forWritingTo: stdoutStreamURL)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutFileHandle.write(data)
            }
        }

        // Launch
        try process.run()
        let pid = process.processIdentifier

        // Store references
        lock.lock()
        processes[job.id] = process
        stdoutHandles[job.id] = stdoutFileHandle
        stderrHandles[job.id] = stderrFileHandle
        lock.unlock()

        return (process, pid)
    }

    /// Get the Process instance for a job
    func getProcess(for jobId: UUID) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return processes[jobId]
    }

    // MARK: - Process Termination

    /// Send SIGTERM to the process
    func terminate(jobId: UUID) {
        lock.lock()
        guard let process = processes[jobId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        if process.isRunning {
            process.terminate() // sends SIGTERM
        }
    }

    /// Send SIGKILL to the process using direct kill syscall
    func forceKill(jobId: UUID) {
        lock.lock()
        guard let process = processes[jobId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        if process.isRunning {
            let pid = process.processIdentifier
            // Kill the process group (negative PID)
            kill(-pid, SIGKILL)
            // Also kill the specific process
            kill(pid, SIGKILL)
        }
    }

    /// Check if a process is still running by PID
    func isProcessAlive(pid: Int32) -> Bool {
        // kill with signal 0 checks if process exists without sending a signal
        return kill(pid, 0) == 0
    }

    /// Wait for process completion with a callback
    func waitForCompletion(jobId: UUID, completion: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        guard let process = processes[jobId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        process.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            self?.cleanup(jobId: jobId)
            completion(exitCode)
        }
    }

    // MARK: - Cleanup

    func cleanup(jobId: UUID) {
        lock.lock()
        if let handle = stdoutHandles.removeValue(forKey: jobId) {
            try? handle.close()
        }
        if let handle = stderrHandles.removeValue(forKey: jobId) {
            try? handle.close()
        }
        processes.removeValue(forKey: jobId)
        lock.unlock()
    }
}
