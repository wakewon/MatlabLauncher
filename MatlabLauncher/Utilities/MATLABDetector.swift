import Foundation

// MARK: - MATLAB Detector

/// Scans for installed MATLAB versions on macOS
struct MATLABDetector {
    struct MATLABInstallation: Identifiable {
        let id = UUID()
        let version: String      // e.g. "R2025b"
        let appPath: String      // e.g. /Applications/MATLAB_R2025b.app
        let binaryPath: String   // e.g. /Applications/MATLAB_R2025b.app/bin/matlab

        var displayName: String {
            "MATLAB \(version)"
        }
    }

    /// Scan /Applications for MATLAB installations
    static func detectInstallations() -> [MATLABInstallation] {
        let fm = FileManager.default
        let appsDir = "/Applications"

        guard let contents = try? fm.contentsOfDirectory(atPath: appsDir) else {
            return []
        }

        var installations: [MATLABInstallation] = []

        for item in contents {
            // Match MATLAB_R20XXx.app pattern
            guard item.hasPrefix("MATLAB_R") && item.hasSuffix(".app") else { continue }

            let appPath = (appsDir as NSString).appendingPathComponent(item)
            let binaryPath = (appPath as NSString).appendingPathComponent("bin/matlab")

            guard fm.isExecutableFile(atPath: binaryPath) else { continue }

            // Extract version from folder name: MATLAB_R2025b.app → R2025b
            let version = item
                .replacingOccurrences(of: "MATLAB_", with: "")
                .replacingOccurrences(of: ".app", with: "")

            installations.append(MATLABInstallation(
                version: version,
                appPath: appPath,
                binaryPath: binaryPath
            ))
        }

        // Sort by version descending (newest first)
        installations.sort { $0.version > $1.version }
        return installations
    }

    /// Get the default (newest) MATLAB installation
    static var defaultInstallation: MATLABInstallation? {
        detectInstallations().first
    }
}
