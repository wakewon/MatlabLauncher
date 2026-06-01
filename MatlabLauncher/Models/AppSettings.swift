import Foundation

// MARK: - App Settings

struct AppSettings: Codable, Equatable {
    var defaultMatlabPath: String
    var dataDirectory: String
    var httpPort: UInt16
    var heartbeatIntervalSeconds: Int
    var heartbeatStaleThresholdSeconds: Int
    var cancelGracePeriodSeconds: Int
    var killEscalationDelaySeconds: Int
    var notificationsEnabled: Bool
    var maxRecentJobs: Int
    var autoStartHTTPServer: Bool
    var hideDockIcon: Bool

    private enum CodingKeys: String, CodingKey {
        case defaultMatlabPath
        case dataDirectory
        case httpPort
        case heartbeatIntervalSeconds
        case heartbeatStaleThresholdSeconds
        case cancelGracePeriodSeconds
        case killEscalationDelaySeconds
        case notificationsEnabled
        case maxRecentJobs
        case autoStartHTTPServer
        case hideDockIcon
    }

    init(
        defaultMatlabPath: String,
        dataDirectory: String,
        httpPort: UInt16,
        heartbeatIntervalSeconds: Int,
        heartbeatStaleThresholdSeconds: Int,
        cancelGracePeriodSeconds: Int,
        killEscalationDelaySeconds: Int,
        notificationsEnabled: Bool,
        maxRecentJobs: Int,
        autoStartHTTPServer: Bool,
        hideDockIcon: Bool
    ) {
        self.defaultMatlabPath = defaultMatlabPath
        self.dataDirectory = dataDirectory
        self.httpPort = httpPort
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.heartbeatStaleThresholdSeconds = heartbeatStaleThresholdSeconds
        self.cancelGracePeriodSeconds = cancelGracePeriodSeconds
        self.killEscalationDelaySeconds = killEscalationDelaySeconds
        self.notificationsEnabled = notificationsEnabled
        self.maxRecentJobs = maxRecentJobs
        self.autoStartHTTPServer = autoStartHTTPServer
        self.hideDockIcon = hideDockIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        defaultMatlabPath = try container.decodeIfPresent(String.self, forKey: .defaultMatlabPath) ?? defaults.defaultMatlabPath
        dataDirectory = try container.decodeIfPresent(String.self, forKey: .dataDirectory) ?? defaults.dataDirectory
        httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? defaults.httpPort
        heartbeatIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatIntervalSeconds) ?? defaults.heartbeatIntervalSeconds
        heartbeatStaleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatStaleThresholdSeconds) ?? defaults.heartbeatStaleThresholdSeconds
        cancelGracePeriodSeconds = try container.decodeIfPresent(Int.self, forKey: .cancelGracePeriodSeconds) ?? defaults.cancelGracePeriodSeconds
        killEscalationDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .killEscalationDelaySeconds) ?? defaults.killEscalationDelaySeconds
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        maxRecentJobs = try container.decodeIfPresent(Int.self, forKey: .maxRecentJobs) ?? defaults.maxRecentJobs
        autoStartHTTPServer = try container.decodeIfPresent(Bool.self, forKey: .autoStartHTTPServer) ?? defaults.autoStartHTTPServer
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? defaults.hideDockIcon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultMatlabPath, forKey: .defaultMatlabPath)
        try container.encode(dataDirectory, forKey: .dataDirectory)
        try container.encode(httpPort, forKey: .httpPort)
        try container.encode(heartbeatIntervalSeconds, forKey: .heartbeatIntervalSeconds)
        try container.encode(heartbeatStaleThresholdSeconds, forKey: .heartbeatStaleThresholdSeconds)
        try container.encode(cancelGracePeriodSeconds, forKey: .cancelGracePeriodSeconds)
        try container.encode(killEscalationDelaySeconds, forKey: .killEscalationDelaySeconds)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(maxRecentJobs, forKey: .maxRecentJobs)
        try container.encode(autoStartHTTPServer, forKey: .autoStartHTTPServer)
        try container.encode(hideDockIcon, forKey: .hideDockIcon)
    }

    static let `default` = AppSettings(
        defaultMatlabPath: "/Applications/MATLAB_R2025b.app/bin/matlab",
        dataDirectory: defaultDataDirectory,
        httpPort: 52698,
        heartbeatIntervalSeconds: 10,
        heartbeatStaleThresholdSeconds: 60,
        cancelGracePeriodSeconds: 30,
        killEscalationDelaySeconds: 5,
        notificationsEnabled: true,
        maxRecentJobs: 50,
        autoStartHTTPServer: true,
        hideDockIcon: true
    )

    static var defaultDataDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MatlabLauncher").path
    }

    var jobsDirectory: String {
        (dataDirectory as NSString).appendingPathComponent("jobs")
    }

    var configFilePath: String {
        (dataDirectory as NSString).appendingPathComponent("config.json")
    }

    // MARK: - Persistence

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = URL(fileURLWithPath: configFilePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    static func load(from path: String? = nil) -> AppSettings {
        let configPath = path ?? AppSettings.default.configFilePath
        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }
}
