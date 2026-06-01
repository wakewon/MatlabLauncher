import Foundation

// MARK: - mlm CLI Tool

/// Command-line interface for Matlab Launcher and Monitor
/// Communicates with the running app via its HTTP API

struct MLMConfig {
    static let defaultHost = "127.0.0.1"
    static let defaultPort: UInt16 = 52698

    static var effectivePort: UInt16 {
        if let envPortString = ProcessInfo.processInfo.environment["MLM_PORT"],
           let envPort = UInt16(envPortString),
           envPort > 0 {
            return envPort
        }

        if let configPort = loadPortFromConfig() {
            return configPort
        }

        return defaultPort
    }

    static var baseURL: String {
        "http://\(defaultHost):\(effectivePort)/api/v1"
    }

    private static func loadPortFromConfig() -> UInt16? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let configURL = appSupport?
            .appendingPathComponent("MatlabLauncher")
            .appendingPathComponent("config.json"),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPort = json["httpPort"] else {
            return nil
        }

        if let port = rawPort as? UInt16 {
            return port
        }
        if let port = rawPort as? Int, port > 0, port <= Int(UInt16.max) {
            return UInt16(port)
        }
        if let portString = rawPort as? String,
           let port = UInt16(portString),
           port > 0 {
            return port
        }
        return nil
    }
}

// MARK: - HTTP Client

final class HTTPRequestResultBox: @unchecked Sendable {
    var responseData: Data?
    var statusCode: Int = 0
    let lock = NSLock()
}

func httpRequest(method: String, path: String, body: Data? = nil) -> (Data?, Int) {
    let semaphore = DispatchSemaphore(value: 0)
    let result = HTTPRequestResultBox()

    let url = URL(string: "\(MLMConfig.baseURL)\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 10

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        result.lock.lock()
        defer {
            result.lock.unlock()
            semaphore.signal()
        }

        if let error = error {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            result.statusCode = -1
        } else if let httpResponse = response as? HTTPURLResponse {
            result.statusCode = httpResponse.statusCode
            result.responseData = data
        }
    }
    task.resume()
    semaphore.wait()

    result.lock.lock()
    defer { result.lock.unlock() }

    return (result.responseData, result.statusCode)
}

func prettyJSON(_ data: Data) -> String {
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: pretty, encoding: .utf8) {
        return str
    }
    return String(data: data, encoding: .utf8) ?? "(no data)"
}

// MARK: - Commands

func cmdHealth() {
    let (data, status) = httpRequest(method: "GET", path: "/health")
    if status == 200, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Cannot reach Matlab Launcher at \(MLMConfig.baseURL) (is the app running?)\n", stderr)
        exit(1)
    }
}

func cmdSubmit(args: [String]) {
    var name = ""
    var command = ""
    var project = ""
    var matlabPath: String?
    var tags: [String]?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--name", "-n":
            i += 1; name = args[i]
        case "--command", "-c":
            i += 1; command = args[i]
        case "--project", "-p":
            i += 1; project = args[i]
        case "--matlab":
            i += 1; matlabPath = args[i]
        case "--tags":
            i += 1; tags = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default:
            fputs("Unknown argument: \(args[i])\n", stderr)
        }
        i += 1
    }

    if name.isEmpty || command.isEmpty || project.isEmpty {
        fputs("Usage: mlm submit --name <name> --command <matlab-code> --project <dir> [--matlab <path>] [--tags <a,b>]\n", stderr)
        exit(1)
    }

    var submission: [String: Any] = [
        "name": name,
        "command": command,
        "workingDirectory": project
    ]
    if let mp = matlabPath { submission["matlabPath"] = mp }
    if let t = tags { submission["tags"] = t }

    guard let body = try? JSONSerialization.data(withJSONObject: submission) else {
        fputs("Error: Failed to encode submission\n", stderr)
        exit(1)
    }

    let (data, status) = httpRequest(method: "POST", path: "/jobs", body: body)
    if status == 201, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Failed to submit job (status \(status))\n", stderr)
        if let data = data { fputs(prettyJSON(data) + "\n", stderr) }
        exit(1)
    }
}

func cmdList(args: [String]) {
    var statusFilter = ""
    var limit = ""

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--status", "-s":
            i += 1; statusFilter = args[i]
        case "--limit", "-l":
            i += 1; limit = args[i]
        default: break
        }
        i += 1
    }

    var path = "/jobs"
    var queryParts: [String] = []
    if !statusFilter.isEmpty { queryParts.append("status=\(statusFilter)") }
    if !limit.isEmpty { queryParts.append("limit=\(limit)") }
    if !queryParts.isEmpty { path += "?" + queryParts.joined(separator: "&") }

    let (data, status) = httpRequest(method: "GET", path: path)
    if status == 200, let data = data {
        // Pretty-print job list
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let jobs = json["jobs"] as? [[String: Any]] {
            if jobs.isEmpty {
                print("No jobs found.")
            } else {
                for job in jobs {
                    let id = (job["id"] as? String) ?? "?"
                    let name = (job["name"] as? String) ?? "?"
                    let jobStatus = (job["status"] as? String) ?? "?"
                    let elapsed = (job["elapsedSeconds"] as? Int).map { formatDuration(Double($0)) } ?? "—"
                    let shortId = String(id.prefix(8))
                    print("  \(statusIcon(jobStatus)) \(shortId)  \(name.padding(toLength: 30, withPad: " ", startingAt: 0))  \(jobStatus.padding(toLength: 12, withPad: " ", startingAt: 0))  \(elapsed)")
                }
                print("\nTotal: \(json["count"] ?? jobs.count) jobs")
            }
        } else {
            print(prettyJSON(data))
        }
    } else {
        fputs("Error: Failed to list jobs\n", stderr)
        exit(1)
    }
}

func cmdStatus(jobId: String) {
    let (data, status) = httpRequest(method: "GET", path: "/jobs/\(jobId)/status")
    if status == 200, let data = data {
        print(prettyJSON(data))
    } else if status == 404 {
        fputs("Error: Job not found\n", stderr)
        exit(1)
    } else {
        fputs("Error: Failed to get status\n", stderr)
        exit(1)
    }
}

func cmdCancel(jobId: String) {
    let (data, status) = httpRequest(method: "POST", path: "/jobs/\(jobId)/cancel")
    if status == 200, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Failed to cancel job (status \(status))\n", stderr)
        if let data = data { fputs(prettyJSON(data) + "\n", stderr) }
        exit(1)
    }
}

func cmdKill(jobId: String) {
    let (data, status) = httpRequest(method: "POST", path: "/jobs/\(jobId)/kill")
    if status == 200, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Failed to kill job (status \(status))\n", stderr)
        if let data = data { fputs(prettyJSON(data) + "\n", stderr) }
        exit(1)
    }
}

func cmdLog(jobId: String, args: [String]) {
    var stream = "stdout"
    var tail = "100"

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--stderr": stream = "stderr"
        case "--tail", "-n":
            i += 1; tail = args[i]
        default: break
        }
        i += 1
    }

    let (data, status) = httpRequest(method: "GET", path: "/jobs/\(jobId)/log?stream=\(stream)&tail=\(tail)")
    if status == 200, let data = data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? String {
            print(content)
        } else {
            print(prettyJSON(data))
        }
    } else {
        fputs("Error: Failed to get log\n", stderr)
        exit(1)
    }
}

func cmdOpen(jobId: String) {
    let (data, status) = httpRequest(method: "GET", path: "/jobs/\(jobId)")
    if status == 200, let data = data,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let dir = json["jobDirectory"] as? String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [dir]
        try? process.run()
        process.waitUntilExit()
    } else {
        fputs("Error: Job not found\n", stderr)
        exit(1)
    }
}

func cmdResult(jobId: String) {
    let (data, status) = httpRequest(method: "GET", path: "/jobs/\(jobId)/result")
    if status == 200, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Failed to get result\n", stderr)
        exit(1)
    }
}

func cmdRetry(jobId: String) {
    let (data, status) = httpRequest(method: "POST", path: "/jobs/\(jobId)/retry")
    if status == 201, let data = data {
        print(prettyJSON(data))
    } else {
        fputs("Error: Failed to retry job (status \(status))\n", stderr)
        if let data = data { fputs(prettyJSON(data) + "\n", stderr) }
        exit(1)
    }
}

// MARK: - Helpers

func statusIcon(_ status: String) -> String {
    switch status {
    case "queued": return "⏳"
    case "starting": return "🔄"
    case "running": return "🔵"
    case "succeeded": return "✅"
    case "failed": return "❌"
    case "canceled": return "⏹"
    case "force_killed": return "⚡"
    case "stale": return "⚠️"
    default: return "❓"
    }
}

func formatDuration(_ seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    let secs = Int(seconds) % 60
    if hours > 0 {
        return String(format: "%dh%02dm%02ds", hours, minutes, secs)
    } else if minutes > 0 {
        return String(format: "%dm%02ds", minutes, secs)
    } else {
        return String(format: "%ds", secs)
    }
}

func printUsage() {
    let usage = """
    mlm — Matlab Launcher and Monitor CLI

    Usage:
      mlm health                          Check if the app is running
      mlm submit --name <n> --command <c> --project <dir> [--matlab <path>] [--tags <a,b>]
      mlm list [--status <s>] [--limit <n>]
      mlm status <job-id>
      mlm cancel <job-id>
      mlm kill <job-id>
      mlm log <job-id> [--stderr] [--tail <n>]
      mlm open <job-id>                   Open job directory in Finder
      mlm result <job-id>
      mlm retry <job-id>

    The app must be running for the CLI to work. Current target port: \(MLMConfig.effectivePort).
    Override port for one command with MLM_PORT, for example: MLM_PORT=52698 mlm health
    """
    print(usage)
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    printUsage()
    exit(0)
}

let command = arguments[0]
let subArgs = Array(arguments.dropFirst())

switch command {
case "health":
    cmdHealth()
case "submit":
    cmdSubmit(args: subArgs)
case "list", "ls":
    cmdList(args: subArgs)
case "status":
    guard let id = subArgs.first else { fputs("Usage: mlm status <job-id>\n", stderr); exit(1) }
    cmdStatus(jobId: id)
case "cancel":
    guard let id = subArgs.first else { fputs("Usage: mlm cancel <job-id>\n", stderr); exit(1) }
    cmdCancel(jobId: id)
case "kill":
    guard let id = subArgs.first else { fputs("Usage: mlm kill <job-id>\n", stderr); exit(1) }
    cmdKill(jobId: id)
case "log":
    guard let id = subArgs.first else { fputs("Usage: mlm log <job-id>\n", stderr); exit(1) }
    cmdLog(jobId: id, args: Array(subArgs.dropFirst()))
case "open":
    guard let id = subArgs.first else { fputs("Usage: mlm open <job-id>\n", stderr); exit(1) }
    cmdOpen(jobId: id)
case "result":
    guard let id = subArgs.first else { fputs("Usage: mlm result <job-id>\n", stderr); exit(1) }
    cmdResult(jobId: id)
case "retry":
    guard let id = subArgs.first else { fputs("Usage: mlm retry <job-id>\n", stderr); exit(1) }
    cmdRetry(jobId: id)
case "-h", "--help", "help":
    printUsage()
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}
