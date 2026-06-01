# Matlab Launcher and Monitor

> 🤖 **Vibe Coding 项目**: 本项目主要通过与 AI 助手协同的 "vibe coding"（直觉式编程）方式构建。我们非常欢迎您 Fork 此仓库，探索代码，并根据您自己的工作流对其进行“魔改”！

一款 macOS 原生菜单栏应用，用于管理长时间运行的 MATLAB 任务。专为 AI 辅助开发工作流（如 Codex, Claude Code 等）设计。在这些工作流中，MATLAB 任务可能需要运行数分钟甚至数小时，而本应用能避免这些任务阻塞 AI IDE。

## 核心特性

- **菜单栏应用** — 常驻状态指示器，可快速查看正在运行或最近完成的任务
- **任务管理** — 提交、监控、取消以及强制终止 MATLAB 任务
- **基于文件的持久化** — 无惧应用重启；每个任务都有独立的目录和日志
- **系统通知** — 当任务完成、失败或无响应时，提供 macOS 原生弹窗提醒
- **HTTP API** — 提供 `localhost:52698` REST API 供程序化调用
- **命令行工具 (`mlm`)** — 为 AI IDE 和脚本提供对 Shell 友好的交互接口
- **心跳监控** — 自动检测无响应或卡死的 MATLAB 进程

## 快速开始

### 编译与构建

```bash
# 前置依赖: Xcode, xcodegen (brew install xcodegen)
xcodegen generate
xcodebuild -scheme MatlabLauncher -configuration Debug build
xcodebuild -scheme mlm -configuration Debug build

# 或者直接使用构建脚本:
chmod +x scripts/build.sh && scripts/build.sh
```

### 启动应用

```bash
open /path/to/MatlabLauncher.app
```

应用启动后，菜单栏会出现一个 "M" 图标。

### 命令行工具 (CLI) 使用

```bash
# 检查应用是否正常运行
mlm health

# 提交一个 MATLAB 任务
mlm submit --name "我的数据分析" \
           --command "init_project; Main_Robust" \
           --project /path/to/matlab/project

# 列出所有任务
mlm list
mlm list --status running

# 查看任务状态
mlm status <job-id>

# 查看日志
mlm log <job-id>
mlm log <job-id> --stderr

# 取消 (优雅退出) / 强制终止
mlm cancel <job-id>
mlm kill <job-id>

# 重试失败的任务
mlm retry <job-id>

# 在访达中打开任务输出目录
mlm open <job-id>
```

`<job-id>` 可以是完整的 UUID（推荐），也可以是 `mlm list` 显示的不引起歧义的简短前缀（例如 `2EDA7521`）。如果简短前缀匹配了多个任务，请使用完整的 UUID。

### HTTP API

```bash
# 健康检查
curl http://localhost:52698/api/v1/health

# 提交任务
curl -X POST http://localhost:52698/api/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"name":"test","workingDirectory":"/tmp","command":"disp(42)"}'

# 获取状态
curl http://localhost:52698/api/v1/jobs/<id>/status

# 列出任务
curl http://localhost:52698/api/v1/jobs?status=running

# 取消 / 终止
curl -X POST http://localhost:52698/api/v1/jobs/<id>/cancel
curl -X POST http://localhost:52698/api/v1/jobs/<id>/kill

# 查看日志
curl http://localhost:52698/api/v1/jobs/<id>/log?stream=stdout&tail=50

# 获取结果
curl http://localhost:52698/api/v1/jobs/<id>/result
```

## 架构说明

```
MatlabLauncher/
├── App/                 # @main 入口, AppDelegate
├── Models/              # 数据模型: Job, AppSettings
├── Core/                # 核心逻辑: JobScheduler, JobRepository, ProcessManager, HeartbeatMonitor
├── Views/               # SwiftUI 视图: MenuBar, MainWindow, Detail, Create, Settings
├── API/                 # HTTP 服务器 (Network.framework) + API 路由
├── Notifications/       # macOS 通知管理器
└── Utilities/           # 工具类: MATLAB 检测器等

mlm/                     # 命令行工具 (独立的 Target)
```

## 数据存储

任务数据默认存储在 `~/Library/Application Support/MatlabLauncher/jobs/<job-id>/` 目录下：

| 文件 | 用途 |
|------|---------|
| `job.json` | 完整的任务定义及状态信息 |
| `status.json` | 轻量级的状态文件，用于快速轮询 |
| `stdout.log` | MATLAB 命令行标准输出 |
| `stderr.log` | 标准错误输出 |
| `heartbeat` | 最新活跃时间戳记录 |
| `result.json` | 结构化的退出信息（成功时生成） |
| `error.json` | 结构化的错误信息（失败时生成） |
| `cancel.flag` | 协作式取消信号文件 |

## 配置选项

配置文件路径 `~/Library/Application Support/MatlabLauncher/config.json`：

- **MATLAB 路径** — 自动检测或手动配置
- **HTTP 端口** — 默认: 52698
- **心跳间隔** — 默认: 10 秒
- **卡死判定阈值** — 默认: 60 秒

## AI IDE 集成

对于 AI 编程流（如 Codex, Claude Code 等），推荐的使用模式为：

1. **提交**: AI 调用 `mlm submit` → 获取 `jobId`
2. **返回**: AI 立即向用户报告 `jobId`，不要在此阻塞轮询
3. **后续检查**: 当用户询问进度时，AI 调用 `mlm status <id>` 或 `mlm log <id>`
4. **无超时担忧**: MATLAB 进程由本应用接管，而非由 AI 进程持有

## 运行要求

- macOS 14.0+ (Sonoma)
- Xcode 16+
- MATLAB (任何支持 `-batch` 的版本, R2019a+)
- xcodegen (用于生成 Xcode 项目)

## 开源协议

MIT

## 发布编译与打包

项目中包含了一个便捷脚本，用于编译 Release 版本的 `.app` 并将其打包为 DMG 和 ZIP 归档，无需配置 Apple Developer 代码签名。

脚本位置: `scripts/release_package.sh`

使用方法:

```bash
# 编译 Release 并创建 DMG 和 ZIP（无需代码签名）
chmod +x scripts/release_package.sh
scripts/release_package.sh

# 如果只需要 ZIP 而不想要 DMG，可以跳过 DMG 创建
scripts/release_package.sh --no-dmg

# 如果你已经编译好了 Release 版本，只想打包现有的 .app
scripts/release_package.sh --skip-build
```

**安装与 Gatekeeper 注意事项:**
- 脚本中禁用了代码签名 (`CODE_SIGNING_ALLOWED=NO`)，因此没有苹果开发者账号也能正常运行。
- 在本地运行无需签名，但 macOS Gatekeeper 可能会发出警告。要打开未签名的应用，请右键点击该应用并选择“打开”。
- 如果将应用拷贝到 `/Applications` 后提示“文件已损坏”，请通过以下命令移除 macOS 的隔离标志：
  ```bash
  xattr -dr com.apple.quarantine /Applications/MatlabLauncher.app
  ```
- 打包的 `.app` 内已将 `mlm` 命令行工具包含在 `Contents/Resources/mlm` 路径下。若需将 `mlm` 软链接或安装至系统路径（如 `/usr/local/bin`），可能需要使用 `sudo` 权限。
