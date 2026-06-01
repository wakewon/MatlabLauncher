# Matlab Launcher and Monitor

> 🤖 **A Vibe Coding Project**: This project was primarily built via "vibe coding" alongside AI assistants. We warmly welcome you to fork the repository, explore the code, and heavily modify it to suit your own workflow!

A macOS-native menu bar application for managing long-running MATLAB tasks. Designed for AI-assisted development workflows (Codex, Claude Code, etc.) where MATLAB jobs need to run for minutes or hours without tying up the AI IDE.

## Features

- **Menu Bar App** — Always-on status indicator with quick access to running/recent tasks
- **Task Management** — Submit, monitor, cancel, and force-kill MATLAB jobs
- **File-Based Persistence** — Survive app restarts; every job gets its own directory with logs
- **System Notifications** — macOS alerts on completion, failure, or stale tasks
- **HTTP API** — `localhost:52698` REST API for programmatic access
- **CLI Tool (`mlm`)** — Shell-friendly interface for AI IDEs and scripts
- **Heartbeat Monitoring** — Detect stale/hung MATLAB processes

## Quick Start

### Build

```bash
# Prerequisites: Xcode, xcodegen (brew install xcodegen)
xcodegen generate
xcodebuild -scheme MatlabLauncher -configuration Debug build
xcodebuild -scheme mlm -configuration Debug build

# Or use the build script:
chmod +x scripts/build.sh && scripts/build.sh
```

### Launch

```bash
open /path/to/MatlabLauncher.app
```

The app appears as an "M" icon in the menu bar.

### CLI Usage

```bash
# Check app is running
mlm health

# Submit a MATLAB job
mlm submit --name "My Analysis" \
           --command "init_project; Main_Robust" \
           --project /path/to/matlab/project

# List all jobs
mlm list
mlm list --status running

# Check job status
mlm status <job-id>

# View logs
mlm log <job-id>
mlm log <job-id> --stderr

# Cancel (graceful) / Kill (force)
mlm cancel <job-id>
mlm kill <job-id>

# Retry a failed job
mlm retry <job-id>

# Open job output directory
mlm open <job-id>
```

`<job-id>` can be either a full UUID (recommended) or an unambiguous short prefix shown by `mlm list` (for example, `2EDA7521`).
If a short prefix matches multiple jobs, use the full UUID.

### HTTP API

```bash
# Health check
curl http://localhost:52698/api/v1/health

# Submit job
curl -X POST http://localhost:52698/api/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"name":"test","workingDirectory":"/tmp","command":"disp(42)"}'

# Get status
curl http://localhost:52698/api/v1/jobs/<id>/status

# List jobs
curl http://localhost:52698/api/v1/jobs?status=running

# Cancel / Kill
curl -X POST http://localhost:52698/api/v1/jobs/<id>/cancel
curl -X POST http://localhost:52698/api/v1/jobs/<id>/kill

# View logs
curl http://localhost:52698/api/v1/jobs/<id>/log?stream=stdout&tail=50

# Get result
curl http://localhost:52698/api/v1/jobs/<id>/result
```

## Architecture

```
MatlabLauncher/
├── App/                 # @main entry, AppDelegate
├── Models/              # Job, AppSettings
├── Core/                # JobScheduler, JobRepository, ProcessManager, HeartbeatMonitor
├── Views/               # SwiftUI views (MenuBar, MainWindow, Detail, Create, Settings)
├── API/                 # HTTP server (Network.framework) + API router
├── Notifications/       # macOS notification manager
└── Utilities/           # MATLAB detector, etc.

mlm/                     # CLI tool (separate target)
```

## Data Storage

Jobs are stored in `~/Library/Application Support/MatlabLauncher/jobs/<job-id>/`:

| File | Purpose |
|------|---------|
| `job.json` | Full job definition and state |
| `status.json` | Lightweight status for polling |
| `stdout.log` | MATLAB command window output |
| `stderr.log` | Error output |
| `heartbeat` | Last liveness timestamp |
| `result.json` | Structured exit info (on success) |
| `error.json` | Structured error info (on failure) |
| `cancel.flag` | Cooperative cancellation signal |

## Configuration

Settings at `~/Library/Application Support/MatlabLauncher/config.json`:

- **MATLAB path** — Auto-detected or manually configured
- **HTTP port** — Default: 52698
- **Heartbeat interval** — Default: 10 seconds
- **Stale threshold** — Default: 60 seconds

## AI IDE Integration

For AI workflows (Codex, Claude Code, etc.), the pattern is:

1. **Submit**: AI calls `mlm submit` → gets `jobId`
2. **Return**: AI reports the `jobId` to the user, doesn't poll
3. **Check later**: When asked, AI calls `mlm status <id>` or `mlm log <id>`
4. **No timeout**: The app owns the process, not the AI

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 16+
- MATLAB (any version with `-batch` support, R2019a+)
- xcodegen (for project generation)

## License

MIT

## Release Build & Packaging

A convenience script is included to build a Release `.app` and package it into a DMG and ZIP archive without requiring Apple Developer code signing.

Location: `scripts/release_package.sh`

Usage:

```bash
# Build Release and create a DMG & ZIP (no code signing)
chmod +x scripts/release_package.sh
scripts/release_package.sh

# Skip the DMG creation if you only want the ZIP
scripts/release_package.sh --no-dmg

# If you already built Release and want only to package the existing .app
scripts/release_package.sh --skip-build
```

**Installation and Gatekeeper Notes:**
- The script disables code signing (`CODE_SIGNING_ALLOWED=NO`) so it works without a Developer ID.
- You DO NOT need to sign the app to run it locally; macOS Gatekeeper may warn. To open an unsigned app, right-click the app and choose "Open" to allow it.
- If users report the app is "damaged" after copying to `/Applications`, remove macOS quarantine flags with:
  ```bash
  xattr -dr com.apple.quarantine /Applications/MatlabLauncher.app
  ```
- The packaged `.app` includes the `mlm` CLI in `Contents/Resources/mlm`. Installing `mlm` to system paths may require `sudo`.
