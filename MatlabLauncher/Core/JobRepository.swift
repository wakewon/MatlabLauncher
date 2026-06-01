import Foundation

struct LogFileSnapshot: Equatable {
    let content: String
    let fileSize: UInt64
    let displayedBytes: UInt64
    let isTruncated: Bool

    static let empty = LogFileSnapshot(content: "", fileSize: 0, displayedBytes: 0, isTruncated: false)
}

// MARK: - Job Repository

/// File-based CRUD for Job objects. Each job gets its own directory.
@MainActor
final class JobRepository: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private let baseDirectory: String
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let tailReadWindowBytes: UInt64 = 1_048_576

    init(baseDirectory: String) {
        self.baseDirectory = baseDirectory
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        ensureDirectoryExists(baseDirectory)
    }

    // MARK: - CRUD Operations

    /// Create a new job with its directory and initial files
    func createJob(from submission: JobSubmission, settings: AppSettings) -> Job {
        let id = UUID()
        let jobDir = (baseDirectory as NSString).appendingPathComponent(id.uuidString)
        ensureDirectoryExists(jobDir)

        var job = Job(
            id: id,
            name: submission.name,
            matlabPath: submission.matlabPath ?? settings.defaultMatlabPath,
            workingDirectory: submission.workingDirectory,
            command: submission.command,
            tags: submission.tags ?? [],
            extraArgs: submission.extraArgs ?? [],
            environment: submission.environment ?? [:],
            jobDirectory: jobDir
        )
        job.status = .queued
        job.createdAt = Date()

        saveJob(job)
        writeStatusFile(for: job)
        jobs.insert(job, at: 0)
        return job
    }

    /// Update an existing job
    func updateJob(_ job: Job) {
        saveJob(job)
        writeStatusFile(for: job)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        }
    }

    /// Get a job by ID
    func getJob(id: UUID) -> Job? {
        return jobs.first { $0.id == id }
    }

    /// Get jobs filtered by status
    func getJobs(status: JobStatus? = nil, limit: Int? = nil) -> [Job] {
        var result = jobs
        if let status = status {
            result = result.filter { $0.status == status }
        }
        result.sort { $0.createdAt > $1.createdAt }
        if let limit = limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    /// Get active (non-terminal) jobs
    var activeJobs: [Job] {
        jobs.filter { $0.status.isActive }
    }

    /// Get recently completed jobs
    func recentTerminalJobs(limit: Int = 10) -> [Job] {
        jobs.filter { $0.status.isTerminal }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Recovery

    /// Load all jobs from disk (for app restart recovery)
    func loadAllJobs() {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: baseDirectory) else {
            return
        }

        var loadedJobs: [Job] = []
        for dirName in contents {
            let jobDir = (baseDirectory as NSString).appendingPathComponent(dirName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: jobDir, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let jobFile = (jobDir as NSString).appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jobFile)),
                  let job = try? decoder.decode(Job.self, from: data) else { continue }

            loadedJobs.append(job)
        }

        loadedJobs.sort { $0.createdAt > $1.createdAt }
        self.jobs = loadedJobs
    }

    // MARK: - File Operations

    /// Write the cancel flag file
    func writeCancelFlag(for job: Job) {
        let flagPath = job.cancelFlagPath
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(toFile: flagPath, atomically: true, encoding: .utf8)
    }

    /// Check if cancel flag exists
    func cancelFlagExists(for job: Job) -> Bool {
        return fileManager.fileExists(atPath: job.cancelFlagPath)
    }

    /// Write result file
    func writeResult(for job: Job, exitCode: Int32, summary: String) {
        let result = JobResult(exitCode: exitCode, summary: summary, finishedAt: Date())
        if let data = try? encoder.encode(result) {
            try? data.write(to: URL(fileURLWithPath: job.resultJSONPath))
        }
    }

    /// Write error file
    func writeError(for job: Job, exitCode: Int32, message: String, lastStderr: String?) {
        let error = JobError(exitCode: exitCode, message: message, lastStderr: lastStderr, finishedAt: Date())
        if let data = try? encoder.encode(error) {
            try? data.write(to: URL(fileURLWithPath: job.errorJSONPath))
        }
    }

    /// Update heartbeat file
    func updateHeartbeat(for job: Job) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(toFile: job.heartbeatPath, atomically: true, encoding: .utf8)
    }

    /// Read the last N lines from a log file
    func tailLog(for job: Job, stream: String = "stdout", lines: Int = 100) -> String {
        guard let data = readTailData(atPath: logPath(for: job, stream: stream), maxBytes: tailReadWindowBytes),
              let content = String(data: data, encoding: .utf8) else {
            return ""
        }
        let allLines = content.components(separatedBy: .newlines)
        let tailLines = allLines.suffix(lines)
        return tailLines.joined(separator: "\n")
    }

    /// Read the entire log content
    func readLog(for job: Job, stream: String = "stdout") -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath(for: job, stream: stream))),
              let content = String(data: data, encoding: .utf8) else {
            return ""
        }
        return content
    }

    /// Read a bounded tail of a log for UI display.
    func readLogTail(for job: Job, stream: String = "stdout", maxBytes: UInt64 = 262_144) -> String {
        Self.readLogTail(atPath: logPath(for: job, stream: stream), maxBytes: maxBytes).content
    }

    nonisolated static func readLogTail(atPath path: String, maxBytes: UInt64) -> LogFileSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return .empty
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return .empty
        }

        let isTruncated = fileSize > maxBytes
        let offset = isTruncated ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)

        guard let data = try? handle.readToEnd() else {
            return .empty
        }

        let content = Self.decodeTailData(data)
        return LogFileSnapshot(
            content: content,
            fileSize: fileSize,
            displayedBytes: UInt64(data.count),
            isTruncated: isTruncated
        )
    }

    // MARK: - Private Helpers

    private func saveJob(_ job: Job) {
        if let data = try? encoder.encode(job) {
            try? data.write(to: URL(fileURLWithPath: job.jobJSONPath))
        }
    }

    private func logPath(for job: Job, stream: String) -> String {
        switch stream {
        case "stderr":
            return job.stderrLogPath
        case "stream":
            return job.stdoutLogPath + ".stream"
        default:
            return job.stdoutLogPath
        }
    }

    private func readTailData(atPath path: String, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    nonisolated private static func decodeTailData(_ data: Data) -> String {
        if let content = String(data: data, encoding: .utf8) {
            return content
        }

        for offset in 1..<min(data.count, 4) {
            if let content = String(data: data.dropFirst(offset), encoding: .utf8) {
                return content
            }
        }

        return ""
    }

    private func writeStatusFile(for job: Job) {
        if let data = try? encoder.encode(job.compactStatus) {
            try? data.write(to: URL(fileURLWithPath: job.statusJSONPath))
        }
    }

    private func ensureDirectoryExists(_ path: String) {
        if !fileManager.fileExists(atPath: path) {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}
