# MacPort 设计与实施方案

## 目标

MacPort 是一个面向个人使用的 macOS 菜单栏端口监控应用，目标系统为 macOS Tahoe 26.5.1、Apple Silicon。它不是使用私有 API 的系统“灵动岛插件”，而是使用 AppKit `NSPanel` 在刘海区域附近显示透明悬浮摘要；用户点击摘要后可以查看端口详情。

首版功能：

- 默认显示监听中的 TCP/UDP 端口，并可切换查看全部连接；
- 通过 `/usr/sbin/lsof` 获取端口、PID、进程和连接状态；
- 记录端口生命周期、开启、关闭、状态和进程变化；
- SQLite 永久保存历史，支持查询和 JSON/CSV 导出；
- 默认不请求管理员权限，权限不足时保留可见数据并明确告知用户；
- 菜单栏状态、刘海悬浮摘要、可滚动详情和诊断页面；
- 启动时执行系统兼容性预检；
- macOS/Tahoe 更新、`lsof` 缺失、输出格式变化、数据库故障和悬浮层故障都有稳定错误编号、原因、影响和处理建议；
- 不上传端口、进程、历史或诊断数据，不自动执行 `sudo`，不修改防火墙或结束进程。

## 工程与环境

主程序使用 Swift 6.3、SwiftUI、AppKit、Foundation 和系统 SQLite，运行时不依赖 Python。应用以菜单栏后台 `.app` 形式构建，不以 App Store 审核为目标。

开发辅助环境使用 `uv`：

```sh
uv run python -m unittest discover -s tools/tests
uv lock
```

Python 工具仅用于生成 `lsof -F` fixture、模拟系统诊断输入和运行辅助测试；主程序不启动 Python。项目内的 `.uv-cache`、`.venv` 和构建产物不纳入版本控制。

## 系统架构

```text
AppDelegate / StatusBarController
        |
        +-- RuntimeController (@MainActor)
        |       +-- PortScanner
        |       +-- DiffEngine
        |       +-- HistoryStore (SQLite actor)
        |       +-- ErrorCenter (actor)
        |       +-- CompatibilityChecker
        |       +-- DiagnosticsStore (SQLite actor)
        |
        +-- NotchOverlayController (NSPanel + SwiftUI)
        +-- DashboardView / HistoryView / DiagnosticsView / SettingsView
```

端口扫描使用固定参数直接启动 `/usr/sbin/lsof`，不经过 shell：

```text
lsof -nP -iTCP -iUDP -a -F pcuLnPT
```

解析器使用字段模式而不是表格空格切分，严格校验 PID、协议、地址和端口。单条异常记录生成解析警告；必需字段整体变化则停止把结果当作可信实时状态。

默认后台扫描间隔为 5 秒，详情面板打开时为 2 秒，可选择 1、5、15、30 秒。单次扫描超时为 3 秒，超时后终止子进程并报告 `SCAN-003`。

## 数据与历史

核心模型包括 `PortRecord`、`PortEndpoint`、`ScanSnapshot`、`PortEvent`、`ScanMode`、`TransportProtocol`、`PortVisibility`、`CompatibilityReport` 和 `UserFacingIssue`。

历史数据库位置：

```text
~/Library/Application Support/MacPort/history.sqlite
```

主要表：

- `scan_runs`：扫描时间、模式、状态、记录数和警告数；
- `port_lifecycles`：端口首次出现、最近观察、结束时间、PID、进程和可见性；
- `port_events`：opened、closed、stateChanged、processChanged、visibilityChanged；
- `schema_meta`：数据库迁移版本。

完全相同的连续扫描不生成重复事件；历史永久保留，只有用户手动清空才删除。数据库使用 WAL、foreign keys、事务和索引。数据库异常不应使实时列表消失：实时监控可以继续，但界面必须明确显示“历史记录暂停保存”。

## 错误与诊断

所有底层错误先转换为 `UserFacingIssue`，再进入 `ErrorCenter`、`os.Logger` 和 UI，不直接把异常堆栈作为用户提示。

统一错误结构包含：错误编号、严重级别、组件、标题、原因、影响、建议操作、技术详情、是否可重试、发生时间和次数。错误中心会按错误编号和上下文去重，保存活跃错误、首次时间、最近时间和次数。

错误编号范围：

- `SYS-001` 至 `SYS-006`：系统版本、架构、资源和能力探测；
- `SCAN-001` 至 `SCAN-008`：`lsof` 缺失、启动失败、超时、退出码、权限、格式变化、空结果和部分结果；
- `PARSE-001` 至 `PARSE-005`：单条记录、字段、协议和端口格式异常；
- `DB-001` 至 `DB-006`：打开、写入、损坏、迁移、锁定和导出；
- `DISPLAY-001` 至 `DISPLAY-003`：显示器和顶部区域检测；
- `OVERLAY-001` 至 `OVERLAY-002`：悬浮面板创建和定位。

必须严格区分：

- `SCAN-007` 表示扫描成功且没有发现端口；
- `SCAN-001` 到 `SCAN-006` 表示扫描失败，不能显示成“没有端口”；
- `SCAN-008` 表示扫描成功但结果不完整。

扫描失败时保留最近一次成功结果，并标记为 `stale`，显示最后成功时间；旧数据不能伪装成实时数据。

诊断信息存储在：

```text
~/Library/Application Support/MacPort/diagnostics.sqlite
```

保留最近 200 条诊断事件。支持诊断页面、重新检查、重新扫描、复制诊断信息和导出 JSON。默认脱敏 IP 地址和完整命令输出，明确告知用户主动导出可能包含进程名、PID 和端口。

## Tahoe 更新兼容策略

首版验证基线为 macOS 26.5.1、Build 25F80、arm64。启动时获取 macOS 版本、Build 号、架构，检查 `/usr/sbin/lsof`、扫描探测、输出格式、SQLite、显示器顶部区域和应用资源。

- 26.5.1/25F80：已验证；
- 26.x 新 Build：执行完整探测并提示“当前系统尚未验证”；
- 27 或更高大版本：执行安全探测并提示新系统；
- 探测通过时可以继续运行但显示未验证警告；
- 必需能力失效时进入 `pausedByCompatibilityIssue`，不继续写入不可信端口数据。

系统更新导致不可用时，错误必须包含当前版本、Build、MacPort 版本、已验证基线、具体失败检查项、旧数据是否过期、重新检测按钮和复制诊断按钮。不能只显示“未知错误”。

## UI

菜单栏显示正常、变化、警告或失败状态。点击后显示当前状态、最后扫描时间、端口列表、扫描模式、刷新、历史、诊断和设置。

刘海悬浮层使用 `NSScreen.safeAreaInsets`、`auxiliaryTopLeftArea` 和 `auxiliaryTopRightArea` 计算顶部中央触发区域。鼠标进入约 150ms 后显示摘要，点击后打开详情；移出约 400ms 后收起。无刘海外接屏回退到顶部中央区域。悬浮层失败时菜单栏和普通详情页继续可用。

## 测试和验收

Swift 测试覆盖：`lsof -F` 的 TCP/UDP、IPv4/IPv6、监听/连接、非法记录、DiffEngine、SQLite 事件生命周期、错误去重、兼容性版本矩阵、过期数据和诊断导出。

`uv run` 辅助测试覆盖 fixture 生成和 JSON 诊断 schema。

本机验收包括：启动 8080 测试服务并发现端口、停止服务并记录关闭、模拟 `lsof` 缺失/超时/格式变化、验证错误而非“无端口”提示、验证恢复后状态回到正常、验证系统版本变化触发预检、验证悬浮层失败不影响菜单栏监控。
