import Foundation
import Network

// MARK: - HTTP Server

enum HTTPServerLifecycleEvent: Sendable {
    case ready(port: UInt16)
    case failed(String)
    case stopped
}

/// Lightweight HTTP server using Network.framework NWListener
final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let router: APIRouter
    private let queue = DispatchQueue(label: "com.matablauncher.httpserver", qos: .userInitiated)
    private var failedToStart = false

    var isRunning: Bool { listener != nil }
    var configuredPort: UInt16 { port }
    var onLifecycleEvent: (@Sendable (HTTPServerLifecycleEvent) -> Void)?

    init(port: UInt16, router: APIRouter) {
        self.port = port
        self.router = router
    }

    func start() throws {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let portValue = port
        let createdListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: portValue)!)
        failedToStart = false

        createdListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[HTTP] Server listening on port \(self.port)")
                self.onLifecycleEvent?(.ready(port: self.port))
            case .failed(let error):
                print("[HTTP] Server failed: \(error)")
                self.failedToStart = true
                self.onLifecycleEvent?(.failed(error.localizedDescription))
                self.listener?.cancel()
                self.listener = nil
            case .cancelled:
                self.listener = nil
                if !self.failedToStart {
                    self.onLifecycleEvent?(.stopped)
                }
                self.failedToStart = false
            default:
                break
            }
        }

        createdListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener = createdListener
        createdListener.start(queue: queue)
    }

    func stop() {
        guard listener != nil else {
            onLifecycleEvent?(.stopped)
            return
        }

        failedToStart = false
        listener?.cancel()
        print("[HTTP] Server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        receiveRequestData(connection: connection, buffer: Data())
    }

    private func receiveRequestData(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data = data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest.tryParse(rawData: nextBuffer) {
                let router = self.router
                Task { @MainActor in
                    let response = router.handle(request)
                    self.sendHTTPResponse(connection: connection, response: response)
                }
                return
            }

            if isComplete {
                self.sendResponse(connection: connection, status: 400, body: ["error": "Incomplete HTTP request"])
                return
            }

            self.receiveRequestData(connection: connection, buffer: nextBuffer)
        }
    }

    private func sendHTTPResponse(connection: NWConnection, response: HTTPResponse) {
        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var httpResponse = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        httpResponse += "Content-Type: application/json; charset=utf-8\r\n"
        httpResponse += "Access-Control-Allow-Origin: *\r\n"
        httpResponse += "Connection: close\r\n"

        let bodyData: Data
        if let body = response.body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            bodyData = (try? encoder.encode(body)) ?? Data()
        } else {
            bodyData = Data()
        }

        httpResponse += "Content-Length: \(bodyData.count)\r\n"
        httpResponse += "\r\n"

        var responseData = httpResponse.data(using: .utf8)!
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponse(connection: NWConnection, status: Int, body: [String: String]) {
        let response = HTTPResponse(status: status, body: AnyCodable(body))
        sendHTTPResponse(connection: connection, response: response)
    }
}

// MARK: - HTTP Request Parser

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    let body: Data?

    static func tryParse(rawData: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = rawData.range(of: separator) else {
            return nil
        }

        let headerData = rawData.subdata(in: rawData.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let fullPath = parts.count > 1 ? String(parts[1]) : "/"

        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = String(pathComponents[1])
            for param in queryString.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    queryParams[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers[String(headerParts[0]).lowercased()] = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = headerRange.upperBound
        let availableBodyLength = rawData.count - bodyStart
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if availableBodyLength < contentLength {
            return nil
        }

        let body: Data?
        if contentLength > 0 {
            body = rawData.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = nil
        }

        return HTTPRequest(method: method, path: path, queryParams: queryParams, headers: headers, body: body)
    }
}

// MARK: - HTTP Response

struct HTTPResponse: Sendable {
    let status: Int
    let body: AnyCodable?
}

// MARK: - AnyCodable wrapper for flexible JSON responses

struct AnyCodable: Encodable, @unchecked Sendable {
    private let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        if let dict = value as? [String: Any] {
            let wrapped = dict.mapValues { AnyCodable($0) }
            try container.encode(wrapped)
        } else if let array = value as? [Any] {
            let wrapped = array.map { AnyCodable($0) }
            try container.encode(wrapped)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let int32 = value as? Int32 {
            try container.encode(int32)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let date = value as? Date {
            try container.encode(ISO8601DateFormatter().string(from: date))
        } else if let uuid = value as? UUID {
            try container.encode(uuid.uuidString)
        } else if value is NSNull {
            try container.encodeNil()
        } else if let encodable = value as? Encodable {
            try encodable.encode(to: encoder)
        } else {
            try container.encode(String(describing: value))
        }
    }
}

// MARK: - Service Manager

@MainActor
final class ServiceManager: ObservableObject {
    enum ListenerState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    enum ProbeState: Equatable {
        case idle
        case healthy
        case unreachable(String)
        case unexpectedResponse(String)
        case httpError(Int)
    }

    enum CLIState: Equatable {
        case ready(String)
        case missing(String)
        case warning(String)
        case error(String)
    }

    @Published private(set) var listenerState: ListenerState = .stopped
    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var lastProbeDate: Date?
    @Published private(set) var lastHTTPError: String?

    @Published private(set) var cliState: CLIState = .missing("CLI not configured")
    @Published private(set) var cliBinaryPath: String?
    @Published private(set) var cliLinkPath: String
    @Published private(set) var cliInstalledCommandPath: String?
    @Published private(set) var cliMessage: String = "CLI not configured"

    private weak var scheduler: JobScheduler?
    private let router: APIRouter
    private var server: HTTPServer?
    private var probeTimer: Timer?
    private var probeInFlight = false

    init(scheduler: JobScheduler) {
        self.scheduler = scheduler
        self.router = APIRouter(scheduler: scheduler)
        self.cliLinkPath = Self.recommendedCLILinkPath()
        self.cliInstalledCommandPath = nil
        refreshCLIStatus()
    }

    func bootstrap() {
        startProbeTimer()

        if scheduler?.settings.autoStartHTTPServer == true {
            startHTTPServer()
        } else {
            listenerState = .stopped
            probeNow()
        }
    }

    func handleSettingsChange(from oldSettings: AppSettings, to newSettings: AppSettings) {
        if oldSettings.httpPort != newSettings.httpPort {
            if newSettings.autoStartHTTPServer || server != nil {
                restartHTTPServer()
            } else {
                probeNow()
            }
            return
        }

        if oldSettings.autoStartHTTPServer != newSettings.autoStartHTTPServer {
            if newSettings.autoStartHTTPServer {
                startHTTPServer()
            } else {
                stopHTTPServer()
            }
        }
    }

    func startHTTPServer() {
        guard let scheduler else {
            listenerState = .failed("Scheduler unavailable")
            return
        }

        let port = scheduler.settings.httpPort

        if let activeServer = server,
           activeServer.isRunning,
           activeServer.configuredPort == port {
            listenerState = .running
            probeNow()
            return
        }

        server?.stop()
        server = nil

        let freshServer = HTTPServer(port: port, router: router)
        freshServer.onLifecycleEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleServerLifecycleEvent(event)
            }
        }

        server = freshServer
        listenerState = .starting
        lastHTTPError = nil

        do {
            try freshServer.start()
        } catch {
            let message = error.localizedDescription
            listenerState = .failed(message)
            lastHTTPError = message
            server = nil
        }

        probeNow()
    }

    func stopHTTPServer() {
        server?.stop()
        server = nil
        listenerState = .stopped
        probeNow()
    }

    func restartHTTPServer() {
        stopHTTPServer()
        startHTTPServer()
    }

    func probeNow() {
        Task { [weak self] in
            await self?.runHealthProbe()
        }
    }

    func refreshCLIStatus() {
        let installedCommandPath = detectInstalledCLICommandPath()
        let binaryPath = detectCLIBinaryPath()

        cliInstalledCommandPath = installedCommandPath
        cliBinaryPath = binaryPath
        cliLinkPath = installedCommandPath ?? Self.recommendedCLILinkPath()

        if let commandPath = installedCommandPath {
            evaluateCLICommand(at: commandPath, expectedBinaryPath: binaryPath)
            return
        }

        if binaryPath != nil {
            cliState = .missing(cliLinkPath)
            cliMessage = "Not installed. Click Install / Update Link to expose this app's bundled CLI."
        } else {
            cliState = .error("Could not find bundled mlm executable.")
            cliMessage = "Rebuild the app so it bundles mlm, then retry CLI installation."
        }
    }

    func installOrUpdateCLI() {
        guard let binaryPath = detectCLIBinaryPath() else {
            cliState = .error("Could not find bundled mlm executable.")
            cliMessage = "Rebuild the app so it bundles mlm, then retry installation."
            return
        }

        let fileManager = FileManager.default
        let linkPath = preferredCLILinkPath(existingCommandPath: detectInstalledCLICommandPath())
        let linkDirectory = (linkPath as NSString).deletingLastPathComponent
        let linkURL = URL(fileURLWithPath: linkPath)
        let expectedBinaryPath = URL(fileURLWithPath: binaryPath).standardizedFileURL.path

        do {
            try fileManager.createDirectory(at: URL(fileURLWithPath: linkDirectory), withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: linkPath) {
                let values = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: linkPath)
                    let resolvedTarget = URL(fileURLWithPath: rawTarget, relativeTo: URL(fileURLWithPath: linkDirectory)).standardizedFileURL.path
                    if resolvedTarget == expectedBinaryPath {
                        cliLinkPath = linkPath
                        cliInstalledCommandPath = linkPath
                        cliState = .ready(linkPath)
                        cliMessage = "CLI already points to this app."
                        return
                    }
                    try fileManager.removeItem(atPath: linkPath)
                } else {
                    throw NSError(
                        domain: "ServiceManager",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "\(linkPath) exists and is not a symlink"]
                    )
                }
            }

            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: binaryPath)
            cliLinkPath = linkPath
            cliBinaryPath = binaryPath
            cliInstalledCommandPath = linkPath
            refreshCLIStatus()
        } catch {
            cliState = .error("Failed to create symlink: \(error.localizedDescription)")
            cliMessage = "Installation failed. If the target directory is protected, choose a user-writable location (for example ~/bin)."
        }
    }

    var currentPort: UInt16 {
        scheduler?.settings.httpPort ?? AppSettings.default.httpPort
    }

    var isHTTPRunning: Bool {
        if case .running = listenerState {
            return true
        }
        return false
    }

    var httpDiagnostic: String? {
        if case .failed(let message) = listenerState {
            if case .healthy = probeState {
                return "Port \(currentPort) is already serving requests. Another app instance may be running."
            }
            return message
        }

        if case .unreachable(let message) = probeState,
           isHTTPRunning {
            return message
        }

        return lastHTTPError
    }

    var cliPathWarning: String? {
        guard cliInstalledCommandPath == nil else { return nil }
        let directory = (cliLinkPath as NSString).deletingLastPathComponent
        guard !Self.isLikelyInShellPATH(directory) else { return nil }
        return "\(directory) may not be in your shell PATH. Add: export PATH=\"\(directory):$PATH\""
    }

    private func startProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeNow()
            }
        }
        probeTimer?.tolerance = 2.0
    }

    private func handleServerLifecycleEvent(_ event: HTTPServerLifecycleEvent) {
        switch event {
        case .ready:
            listenerState = .running
            lastHTTPError = nil
        case .failed(let message):
            listenerState = .failed(message)
            lastHTTPError = message
            server = nil
        case .stopped:
            if case .failed = listenerState {
                return
            }
            listenerState = .stopped
        }
    }

    private func runHealthProbe() async {
        guard !probeInFlight else { return }
        probeInFlight = true
        defer {
            probeInFlight = false
            lastProbeDate = Date()
        }

        let port = currentPort
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/health") else {
            probeState = .unexpectedResponse("Invalid probe URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                probeState = .unexpectedResponse("Received a non-HTTP response")
                return
            }

            guard httpResponse.statusCode == 200 else {
                probeState = .httpError(httpResponse.statusCode)
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let status = json?["status"] as? String,
               status == "ok" {
                probeState = .healthy
            } else {
                probeState = .unexpectedResponse("Health payload missing status=ok")
            }
        } catch {
            probeState = .unreachable(error.localizedDescription)
        }
    }

    private func evaluateCLICommand(at commandPath: String, expectedBinaryPath: String?) {
        let fileManager = FileManager.default
        let commandURL = URL(fileURLWithPath: commandPath)
        let commandDirectory = commandURL.deletingLastPathComponent().path

        guard let expectedBinaryPath else {
            cliState = .error("Bundled CLI executable not found in the app.")
            cliMessage = "Rebuild the app so it bundles mlm, then click Install / Update Link."
            return
        }
        let expectedPath = URL(fileURLWithPath: expectedBinaryPath).standardizedFileURL.path

        guard fileManager.fileExists(atPath: commandPath) else {
            cliState = .missing(commandPath)
            cliMessage = "CLI command path was not found."
            return
        }

        do {
            let values = try commandURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: commandPath)
                let resolvedTarget = URL(fileURLWithPath: rawTarget, relativeTo: URL(fileURLWithPath: commandDirectory)).standardizedFileURL.path

                if resolvedTarget == expectedPath {
                    cliState = .ready(commandPath)
                    cliMessage = "CLI ready"
                } else {
                    cliState = .error("CLI symlink does not point to this app's bundled mlm")
                    cliMessage = "CLI link points to a different app/build. Click Install / Update Link to replace it."
                }
            } else {
                cliState = .error("\(commandPath) is not a managed symlink")
                cliMessage = "CLI command is not managed by this app. Click Install / Update Link to replace it with a symlink."
            }
        } catch {
            cliState = .error("Failed to inspect CLI command: \(error.localizedDescription)")
            cliMessage = "Failed to inspect installed CLI command."
        }
    }

    private func detectCLIBinaryPath() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("mlm").path)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mlm").path)

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func detectInstalledCLICommandPath() -> String? {
        let fileManager = FileManager.default

        let shellResolvedPaths = resolveShellCommandPaths("mlm")
        if let shellMatch = shellResolvedPaths.first(where: { fileManager.fileExists(atPath: $0) }) {
            return shellMatch
        }

        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/mlm",
            "/usr/local/bin/mlm",
            "\(home)/bin/mlm",
            "\(home)/.local/bin/mlm"
        ]

        return candidates.first(where: { fileManager.fileExists(atPath: $0) })
    }

    private func preferredCLILinkPath(existingCommandPath: String?) -> String {
        let fileManager = FileManager.default

        if let existingCommandPath {
            let directory = (existingCommandPath as NSString).deletingLastPathComponent
            if fileManager.fileExists(atPath: directory),
               fileManager.isWritableFile(atPath: directory) {
                return existingCommandPath
            }
        }

        return Self.recommendedCLILinkPath()
    }

    private func resolveShellCommandPaths(_ command: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "whence -ap \(command)"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
            .filter { seen.insert($0).inserted }
    }

    private static func recommendedCLILinkPath() -> String {
        let directory = recommendedCLIDirectory()
        return (directory as NSString).appendingPathComponent("mlm")
    }

    private static func recommendedCLIDirectory() -> String {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/bin",
            "\(home)/.local/bin",
        ].map(normalizePath)
        let candidateSet = Set(candidates)

        let orderedPathEntries = orderedPATHEntries()

        for pathEntry in orderedPathEntries where candidateSet.contains(pathEntry) {
            if canUseDirectory(pathEntry, fileManager: fileManager) {
                return pathEntry
            }
        }

        for candidate in candidates {
            if canUseDirectory(candidate, fileManager: fileManager) {
                return candidate
            }
        }

        return normalizePath("\(home)/bin")
    }

    private static func canUseDirectory(_ directory: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) {
            return isDirectory.boolValue && fileManager.isWritableFile(atPath: directory)
        }

        let parentDirectory = (directory as NSString).deletingLastPathComponent
        return fileManager.fileExists(atPath: parentDirectory) && fileManager.isWritableFile(atPath: parentDirectory)
    }

    private static func isLikelyInShellPATH(_ directory: String) -> Bool {
        let target = normalizePath(directory)
        return Set(orderedPATHEntries()).contains(target)
    }

    private static func orderedPATHEntries() -> [String] {
        var seen = Set<String>()
        let combined = shellPATHEntries() + processPATHEntries()
        return combined
            .map(normalizePath)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func processPATHEntries() -> [String] {
        cachedProcessPATHEntries
    }

    private static func shellPATHEntries() -> [String] {
        cachedShellPATHEntries
    }

    private static let cachedProcessPATHEntries: [String] = {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
    }()

    private static let cachedShellPATHEntries: [String] = loadShellPATHEntries()

    private static func loadShellPATHEntries() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "print -r -- \"$PATH\""]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }

        return output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
