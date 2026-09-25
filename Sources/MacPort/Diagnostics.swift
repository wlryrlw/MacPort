import Foundation
import os

enum IssueFactory {
    static func make(for error: Error, system: SystemInfo = .current()) -> UserFacingIssue {
        let now = Date()
        let detail = error.localizedDescription
        switch error {
        case MacPortError.scannerMissing(let path):
            return issue(code: "SCAN-001", severity: .critical, component: .scanner,
                         title: "找不到端口扫描程序", reason: "系统中找不到 \(path)。",
                         impact: "MacPort 无法读取当前端口，不能把结果解释为“没有端口”。",
                         action: "确认系统文件存在，然后点击“重新检测”；如果系统刚更新，请检查是否有 MacPort 新版本。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.scannerNotExecutable:
            return issue(code: "SCAN-002", severity: .error, component: .scanner,
                         title: "端口扫描程序不可执行", reason: "系统扫描程序存在，但当前应用无法执行它。",
                         impact: "端口监控已暂停。",
                         action: "检查应用权限和系统状态，然后点击“重新检测”。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.processLaunchFailed:
            return issue(code: "SCAN-002", severity: .error, component: .scanner,
                         title: "无法启动端口扫描进程", reason: "MacPort 无法启动系统端口扫描进程。",
                         impact: "端口监控已暂停。",
                         action: "点击“重新检测”；如果问题持续，请复制诊断信息。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.processTimedOut:
            return issue(code: "SCAN-003", severity: .error, component: .scanner,
                         title: "端口扫描超时", reason: "系统扫描进程在规定时间内没有返回结果。",
                         impact: "本次扫描无效，最近一次成功结果可能已经过期。",
                         action: "稍后重试；如果连续超时，请复制诊断信息。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.nonZeroExit:
            return issue(code: "SCAN-004", severity: .error, component: .scanner,
                         title: "端口扫描进程异常退出", reason: "系统端口扫描命令返回了非零退出码。",
                         impact: "本次扫描无效，不能显示为“没有端口”。",
                         action: "点击“重新检测”；如果问题持续，请复制诊断信息。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.outputFormatChanged:
            return issue(code: "SCAN-006", severity: .critical, component: .compatibility,
                         title: "系统扫描输出格式发生变化", reason: "macOS 返回的 lsof 数据格式与当前解析器不兼容。",
                         impact: "MacPort 已暂停自动监控，以免展示错误的端口信息。",
                         action: "检查是否有 MacPort 新版本，并复制诊断信息。",
                         detail: detail, retryable: false, now: now)
        case MacPortError.parserFailure, MacPortError.unsupportedProtocol, MacPortError.invalidPort:
            return issue(code: "PARSE-001", severity: .warning, component: .parser,
                         title: "部分端口记录无法解析", reason: "系统返回了格式异常或不完整的端口记录。",
                         impact: "列表可能缺少部分端口，但成功解析的记录仍然可用。",
                         action: "点击“复制诊断信息”以保存解析摘要。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.compatibilityBlocked:
            return issue(code: "SYS-003", severity: .critical, component: .compatibility,
                         title: "当前系统不兼容 MacPort", reason: "系统更新后，MacPort 无法访问端口监控所需的能力。",
                         impact: "自动端口监控已暂停；已有结果会标记为过期。",
                         action: "点击“重新检测”，检查 MacPort 更新，并复制诊断信息。",
                         detail: "\(detail); system=\(system.version); build=\(system.build)", retryable: true, now: now)
        case MacPortError.databaseOpenFailed:
            return issue(code: "DB-001", severity: .error, component: .database,
                         title: "历史数据库无法打开", reason: "MacPort 无法打开本地历史数据库。",
                         impact: "实时端口监控可能仍可用，但历史记录不可访问。",
                         action: "确认磁盘和文件权限，然后复制诊断信息；MacPort 不会自动覆盖旧数据库。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.databaseOperationFailed:
            return issue(code: "DB-002", severity: .warning, component: .database,
                         title: "历史记录暂时无法保存", reason: "本地 SQLite 数据库写入失败。",
                         impact: "当前端口可以继续显示，但本次变化可能不会写入历史。",
                         action: "检查磁盘空间和数据库权限，然后点击“重新检测”。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.exportFailed:
            return issue(code: "DB-006", severity: .error, component: .database,
                         title: "诊断信息导出失败", reason: "MacPort 无法创建诊断报告文件。",
                         impact: "当前监控不受影响，但报告没有生成。",
                         action: "检查磁盘空间和目标文件权限，然后重试。",
                         detail: detail, retryable: true, now: now)
        case MacPortError.overlayUnavailable:
            return issue(code: "OVERLAY-001", severity: .warning, component: .overlay,
                         title: "刘海悬浮层不可用", reason: "MacPort 无法创建或定位顶部悬浮面板。",
                         impact: "菜单栏和普通端口详情仍然可用。",
                         action: "重新检测显示器；你也可以继续从菜单栏查看端口。",
                         detail: detail, retryable: true, now: now)
        default:
            return issue(code: "SYS-006", severity: .error, component: .application,
                         title: "MacPort 遇到未分类错误", reason: "应用无法完成当前操作。",
                         impact: "部分功能可能暂时不可用。",
                         action: "点击“重新检测”并复制诊断信息。",
                         detail: detail, retryable: true, now: now)
        }
    }

    static func unverifiedSystem(system: SystemInfo) -> UserFacingIssue {
        issue(code: "SYS-002", severity: .warning, component: .compatibility,
              title: "当前系统尚未经过验证",
              reason: "当前系统版本或 Build 号与 MacPort 的验证基线不同。",
              impact: "MacPort 会继续执行能力探测，但部分功能可能受系统更新影响。",
              action: "如果监控异常，请点击“重新检测”并复制诊断信息。",
              detail: "current=\(system.version) build=\(system.build); baseline=26.5.1/25F80",
              retryable: true, now: Date())
    }

    static func permissionWarning(detail: String) -> UserFacingIssue {
        issue(code: "SCAN-005", severity: .warning, component: .permission,
              title: "部分端口信息受权限限制",
              reason: "macOS 没有向当前用户提供全部进程或连接信息。",
              impact: "列表仍会显示可见端口，但可能缺少系统进程、PID 或进程名。",
              action: "继续使用可见结果；如果需要排查，请复制诊断信息。",
              detail: detail, retryable: false, now: Date())
    }

    private static func issue(code: String, severity: IssueSeverity, component: IssueComponent,
                              title: String, reason: String, impact: String,
                              action: String, detail: String?, retryable: Bool,
                              now: Date) -> UserFacingIssue {
        UserFacingIssue(id: UUID(), code: code, severity: severity, component: component,
                        title: title, reason: reason, impact: impact,
                        suggestedAction: action, technicalDetail: detail,
                        retryable: retryable, occurredAt: now, occurrenceCount: 1)
    }
}

actor ErrorCenter {
    private var active: [String: UserFacingIssue] = [:]
    private let logger = Logger(subsystem: "com.macport.app", category: "diagnostics")

    func report(_ issue: UserFacingIssue) {
        if let existing = active[issue.fingerprint] {
            active[issue.fingerprint] = existing.incremented(at: issue.occurredAt)
        } else {
            active[issue.fingerprint] = issue
        }
        logger.error("MacPort issue \(issue.code, privacy: .public): \(issue.reason, privacy: .public)")
    }

    func resolve(code: String) {
        active = active.filter { $0.value.code != code }
    }

    func clear(_ issueID: UUID) {
        active = active.filter { $0.value.id != issueID }
    }

    func currentIssues() -> [UserFacingIssue] {
        active.values.sorted { lhs, rhs in
            if lhs.severity.rank != rhs.severity.rank {
                return lhs.severity.rank > rhs.severity.rank
            }
            return lhs.occurredAt > rhs.occurredAt
        }
    }
}
