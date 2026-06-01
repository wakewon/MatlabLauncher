import Foundation

// MARK: - Job Status

enum JobStatus: String, Codable, CaseIterable {
    case queued
    case starting
    case running
    case succeeded
    case failed
    case canceled
    case forceKilled = "force_killed"
    case stale

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled, .forceKilled:
            return true
        default:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .starting, .running, .stale:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .forceKilled: return "Force Killed"
        case .stale: return "Stale"
        }
    }

    var sfSymbol: String {
        switch self {
        case .queued: return "clock"
        case .starting: return "arrow.up.circle"
        case .running: return "play.circle.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "stop.circle.fill"
        case .forceKilled: return "bolt.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        }
    }

    var color: String {
        switch self {
        case .queued: return "secondary"
        case .starting: return "blue"
        case .running: return "blue"
        case .succeeded: return "green"
        case .failed: return "red"
        case .canceled: return "orange"
        case .forceKilled: return "red"
        case .stale: return "yellow"
        }
    }
}

// MARK: - Job

struct Job: Codable, Identifiable, Equatable {
    // ── Identity ──
    let id: UUID
    var name: String
    var tags: [String]

    // ── MATLAB Configuration ──
    var matlabPath: String
    var workingDirectory: String
    var command: String
    var extraArgs: [String]
    var environment: [String: String]

    // ── State ──
    var status: JobStatus
    var pid: Int32?
    var exitCode: Int32?

    // ── Timestamps ──
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var lastHeartbeat: Date?

    // ── Paths ──
    var jobDirectory: String

    // ── Results ──
    var resultSummary: String?
    var errorSummary: String?

    // ── Retry ──
    var retryOf: UUID?

    // MARK: - Computed Properties

    var elapsedTime: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = finishedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    var elapsedTimeFormatted: String {
        guard let elapsed = elapsedTime else { return "—" }
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    // ── File paths within job directory ──
    var jobJSONPath: String { (jobDirectory as NSString).appendingPathComponent("job.json") }
    var statusJSONPath: String { (jobDirectory as NSString).appendingPathComponent("status.json") }
    var stdoutLogPath: String { (jobDirectory as NSString).appendingPathComponent("stdout.log") }
    var stderrLogPath: String { (jobDirectory as NSString).appendingPathComponent("stderr.log") }
    var heartbeatPath: String { (jobDirectory as NSString).appendingPathComponent("heartbeat") }
    var resultJSONPath: String { (jobDirectory as NSString).appendingPathComponent("result.json") }
    var errorJSONPath: String { (jobDirectory as NSString).appendingPathComponent("error.json") }
    var cancelFlagPath: String { (jobDirectory as NSString).appendingPathComponent("cancel.flag") }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        matlabPath: String,
        workingDirectory: String,
        command: String,
        tags: [String] = [],
        extraArgs: [String] = [],
        environment: [String: String] = [:],
        retryOf: UUID? = nil,
        jobDirectory: String = ""
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.matlabPath = matlabPath
        self.workingDirectory = workingDirectory
        self.command = command
        self.extraArgs = extraArgs
        self.environment = environment
        self.status = .queued
        self.pid = nil
        self.exitCode = nil
        self.createdAt = Date()
        self.startedAt = nil
        self.finishedAt = nil
        self.lastHeartbeat = nil
        self.jobDirectory = jobDirectory
        self.resultSummary = nil
        self.errorSummary = nil
        self.retryOf = retryOf
    }

    static func == (lhs: Job, rhs: Job) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Job Submission (DTO for API)

struct JobSubmission: Codable {
    var name: String
    var matlabPath: String?
    var workingDirectory: String
    var command: String
    var tags: [String]?
    var extraArgs: [String]?
    var environment: [String: String]?
}

// MARK: - Compact Status (for status.json and API)

struct JobCompactStatus: Codable {
    let id: UUID
    let status: JobStatus
    let pid: Int32?
    let startedAt: Date?
    let finishedAt: Date?
    let elapsedSeconds: TimeInterval?
    let lastHeartbeat: Date?
    let exitCode: Int32?
}

extension Job {
    var compactStatus: JobCompactStatus {
        JobCompactStatus(
            id: id,
            status: status,
            pid: pid,
            startedAt: startedAt,
            finishedAt: finishedAt,
            elapsedSeconds: elapsedTime,
            lastHeartbeat: lastHeartbeat,
            exitCode: exitCode
        )
    }
}

// MARK: - Job Result / Error (for result.json / error.json)

struct JobResult: Codable {
    let exitCode: Int32
    let summary: String
    let finishedAt: Date
}

struct JobError: Codable {
    let exitCode: Int32
    let message: String
    let lastStderr: String?
    let finishedAt: Date
}
