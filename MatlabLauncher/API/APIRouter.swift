import Foundation

// MARK: - API Router

/// Routes HTTP requests to the appropriate handler
@MainActor
final class APIRouter {
    private weak var scheduler: JobScheduler?

    init(scheduler: JobScheduler) {
        self.scheduler = scheduler
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        // Route matching
        let path = request.path
        let method = request.method

        // Health check
        if path == "/api/v1/health" && method == "GET" {
            return handleHealth()
        }

        // Jobs collection
        if path == "/api/v1/jobs" {
            switch method {
            case "GET": return handleListJobs(request)
            case "POST": return handleSubmitJob(request)
            default: return HTTPResponse(status: 405, body: AnyCodable(["error": "Method not allowed"]))
            }
        }

        // Individual job routes
        if path.hasPrefix("/api/v1/jobs/") {
            let remaining = String(path.dropFirst("/api/v1/jobs/".count))
            let parts = remaining.split(separator: "/", maxSplits: 1)

                        guard let jobIdString = parts.first,
                                    let jobId = resolveJobID(String(jobIdString)) else {
                return HTTPResponse(status: 400, body: AnyCodable(["error": "Invalid job ID"]))
            }

            if parts.count == 1 {
                // /api/v1/jobs/{id}
                if method == "GET" {
                    return handleGetJob(jobId)
                }
                return HTTPResponse(status: 405, body: AnyCodable(["error": "Method not allowed"]))
            }

            let action = String(parts[1])
            switch (method, action) {
            case ("GET", "status"):
                return handleGetJobStatus(jobId)
            case ("POST", "cancel"):
                return handleCancelJob(jobId)
            case ("POST", "kill"):
                return handleKillJob(jobId)
            case ("GET", "log"):
                return handleGetLog(jobId, request)
            case ("GET", "result"):
                return handleGetResult(jobId)
            case ("POST", "retry"):
                return handleRetryJob(jobId)
            default:
                return HTTPResponse(status: 404, body: AnyCodable(["error": "Not found"]))
            }
        }

        return HTTPResponse(status: 404, body: AnyCodable(["error": "Not found"]))
    }

    // MARK: - Handlers

    private func handleHealth() -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }
        let activeCount = scheduler.repository.activeJobs.count
        let totalCount = scheduler.repository.jobs.count
        return HTTPResponse(status: 200, body: AnyCodable([
            "status": "ok",
            "activeJobs": activeCount,
            "totalJobs": totalCount
        ] as [String: Any]))
    }

    private func handleListJobs(_ request: HTTPRequest) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        let statusFilter = request.queryParams["status"].flatMap { JobStatus(rawValue: $0) }
        let limit = request.queryParams["limit"].flatMap { Int($0) }

        let jobs = scheduler.repository.getJobs(status: statusFilter, limit: limit)
        let jobDicts = jobs.map { jobToDict($0) }

        return HTTPResponse(status: 200, body: AnyCodable(["jobs": jobDicts, "count": jobDicts.count] as [String: Any]))
    }

    private func handleSubmitJob(_ request: HTTPRequest) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let body = request.body else {
            return HTTPResponse(status: 400, body: AnyCodable(["error": "Request body required"]))
        }

        let decoder = JSONDecoder()
        guard let submission = try? decoder.decode(JobSubmission.self, from: body) else {
            return HTTPResponse(status: 400, body: AnyCodable(["error": "Invalid job submission JSON. Required fields: name, workingDirectory, command"]))
        }

        let job = scheduler.submitJob(submission)

        return HTTPResponse(status: 201, body: AnyCodable([
            "id": job.id.uuidString,
            "status": job.status.rawValue,
            "jobDirectory": job.jobDirectory
        ] as [String: Any]))
    }

    private func handleGetJob(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        return HTTPResponse(status: 200, body: AnyCodable(jobToDict(job)))
    }

    private func handleGetJobStatus(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        return HTTPResponse(status: 200, body: AnyCodable([
            "id": job.id.uuidString,
            "status": job.status.rawValue,
            "pid": (job.pid.map { String($0) }) ?? "null",
            "startedAt": job.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "null",
            "finishedAt": job.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "null",
            "elapsedSeconds": job.elapsedTime.map { String(Int($0)) } ?? "null",
            "lastHeartbeat": job.lastHeartbeat.map { ISO8601DateFormatter().string(from: $0) } ?? "null",
            "exitCode": job.exitCode.map { String($0) } ?? "null"
        ] as [String: Any]))
    }

    private func handleCancelJob(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        guard job.status.isActive else {
            return HTTPResponse(status: 400, body: AnyCodable(["error": "Job is not active (status: \(job.status.rawValue))"]))
        }

        scheduler.cancelJob(id: id)
        return HTTPResponse(status: 200, body: AnyCodable(["message": "Cancel requested", "id": id.uuidString] as [String: Any]))
    }

    private func handleKillJob(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        guard job.status.isActive else {
            return HTTPResponse(status: 400, body: AnyCodable(["error": "Job is not active (status: \(job.status.rawValue))"]))
        }

        scheduler.forceKillJob(id: id)
        return HTTPResponse(status: 200, body: AnyCodable(["message": "Force kill executed", "id": id.uuidString] as [String: Any]))
    }

    private func handleGetLog(_ id: UUID, _ request: HTTPRequest) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        let stream = request.queryParams["stream"] ?? "stdout"
        let tail = Int(request.queryParams["tail"] ?? "100") ?? 100

        let content = scheduler.repository.tailLog(for: job, stream: stream, lines: tail)

        return HTTPResponse(status: 200, body: AnyCodable([
            "jobId": id.uuidString,
            "stream": stream,
            "lines": tail,
            "content": content
        ] as [String: Any]))
    }

    private func handleGetResult(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let job = scheduler.repository.getJob(id: id) else {
            return HTTPResponse(status: 404, body: AnyCodable(["error": "Job not found"]))
        }

        var result: [String: Any] = [
            "id": job.id.uuidString,
            "status": job.status.rawValue,
            "name": job.name
        ]

        if let summary = job.resultSummary {
            result["resultSummary"] = summary
        }
        if let error = job.errorSummary {
            result["errorSummary"] = error
        }
        if let exitCode = job.exitCode {
            result["exitCode"] = String(exitCode)
        }

        return HTTPResponse(status: 200, body: AnyCodable(result))
    }

    private func handleRetryJob(_ id: UUID) -> HTTPResponse {
        guard let scheduler = scheduler else {
            return HTTPResponse(status: 500, body: AnyCodable(["error": "Scheduler not available"]))
        }

        guard let newJob = scheduler.retryJob(id: id) else {
            return HTTPResponse(status: 400, body: AnyCodable(["error": "Cannot retry: job not found or not in terminal state"]))
        }

        return HTTPResponse(status: 201, body: AnyCodable([
            "id": newJob.id.uuidString,
            "status": newJob.status.rawValue,
            "retryOf": id.uuidString,
            "jobDirectory": newJob.jobDirectory
        ] as [String: Any]))
    }

    // MARK: - Helpers

    private func jobToDict(_ job: Job) -> [String: Any] {
        var dict: [String: Any] = [
            "id": job.id.uuidString,
            "name": job.name,
            "status": job.status.rawValue,
            "matlabPath": job.matlabPath,
            "workingDirectory": job.workingDirectory,
            "command": job.command,
            "createdAt": ISO8601DateFormatter().string(from: job.createdAt),
            "jobDirectory": job.jobDirectory,
            "tags": job.tags
        ]
        if let pid = job.pid { dict["pid"] = pid }
        if let exitCode = job.exitCode { dict["exitCode"] = exitCode }
        if let startedAt = job.startedAt { dict["startedAt"] = ISO8601DateFormatter().string(from: startedAt) }
        if let finishedAt = job.finishedAt { dict["finishedAt"] = ISO8601DateFormatter().string(from: finishedAt) }
        if let elapsed = job.elapsedTime { dict["elapsedSeconds"] = Int(elapsed) }
        if let heartbeat = job.lastHeartbeat { dict["lastHeartbeat"] = ISO8601DateFormatter().string(from: heartbeat) }
        if let result = job.resultSummary { dict["resultSummary"] = result }
        if let error = job.errorSummary { dict["errorSummary"] = error }
        if let retryOf = job.retryOf { dict["retryOf"] = retryOf.uuidString }
        return dict
    }

    private func resolveJobID(_ raw: String) -> UUID? {
        if let exact = UUID(uuidString: raw) {
            return exact
        }

        guard let scheduler = scheduler else {
            return nil
        }

        let normalized = raw.uppercased()
        let matches = scheduler.repository.jobs.map(\ .id).filter { uuid in
            uuid.uuidString.uppercased().hasPrefix(normalized)
        }

        // Only accept unambiguous short IDs.
        if matches.count == 1 {
            return matches[0]
        }

        return nil
    }
}
