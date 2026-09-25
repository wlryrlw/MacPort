import Foundation

enum ScanMode: String, Codable, CaseIterable, Sendable {
    case listeners
    case allConnections

    var displayName: String {
        switch self {
        case .listeners: return "监听端口"
        case .allConnections: return "全部连接"
        }
    }
}

enum TransportProtocol: String, Codable, Hashable, Sendable {
    case tcp
    case tcp6
    case udp
    case udp6

    init?(lsofValue: String) {
        switch lsofValue.uppercased() {
        case "TCP": self = .tcp
        case "TCP6": self = .tcp6
        case "UDP": self = .udp
        case "UDP6": self = .udp6
        default: return nil
        }
    }

    var displayName: String { rawValue.uppercased() }
}

enum PortVisibility: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
}

struct PortEndpoint: Codable, Hashable, Sendable {
    let address: String
    let port: UInt16

    var displayValue: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

struct PortRecord: Codable, Hashable, Identifiable, Sendable {
    let stableKey: String
    let protocolType: TransportProtocol
    let localEndpoint: PortEndpoint
    let remoteEndpoint: PortEndpoint?
    let state: String?
    let processID: Int32?
    let processName: String?
    let userName: String?
    let visibility: PortVisibility

    var id: String { stableKey }

    var isListener: Bool {
        if state?.uppercased() == "LISTEN" { return true }
        switch protocolType {
        case .udp, .udp6:
            return remoteEndpoint == nil
        case .tcp, .tcp6:
            return false
        }
    }

    var displayName: String {
        let process = processName ?? "未知进程"
        let pid = processID.map(String.init) ?? "?"
        return "\(process) (PID \(pid))"
    }
}

struct ScanSnapshot: Codable, Sendable {
    let scannedAt: Date
    let mode: ScanMode
    let records: [PortRecord]
    let warnings: [String]
}

enum PortEventType: String, Codable, Sendable {
    case opened
    case closed
    case stateChanged
    case processChanged
    case visibilityChanged
}

struct PortEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let type: PortEventType
    let port: PortRecord
    let previousValue: String?
}

struct ScanResult: Sendable {
    let snapshot: ScanSnapshot
    let visibility: PortVisibility
}

enum MonitoringState: Sendable, Equatable {
    case starting
    case ready
    case scanning
    case readyWithWarnings
    case stale(lastSuccessfulScan: Date)
    case pausedByCompatibilityIssue
    case pausedByUser
    case failed

    var displayName: String {
        switch self {
        case .starting: return "启动中"
        case .ready: return "正常"
        case .scanning: return "扫描中"
        case .readyWithWarnings: return "部分可用"
        case .stale: return "数据已过期"
        case .pausedByCompatibilityIssue: return "系统兼容性问题"
        case .pausedByUser: return "已暂停"
        case .failed: return "扫描失败"
        }
    }
}

enum IssueSeverity: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
    case critical

    var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        case .critical: return 3
        }
    }
}

enum IssueComponent: String, Codable, Sendable {
    case system
    case compatibility
    case scanner
    case parser
    case permission
    case database
    case display
    case overlay
    case application
}

struct UserFacingIssue: Codable, Identifiable, Sendable {
    let id: UUID
    let code: String
    let severity: IssueSeverity
    let component: IssueComponent
    let title: String
    let reason: String
    let impact: String
    let suggestedAction: String
    let technicalDetail: String?
    let retryable: Bool
    let occurredAt: Date
    let occurrenceCount: Int

    var fingerprint: String {
        "\(code)|\(technicalDetail ?? "")"
    }

    func incremented(at date: Date) -> UserFacingIssue {
        UserFacingIssue(
            id: id,
            code: code,
            severity: severity,
            component: component,
            title: title,
            reason: reason,
            impact: impact,
            suggestedAction: suggestedAction,
            technicalDetail: technicalDetail,
            retryable: retryable,
            occurredAt: date,
            occurrenceCount: occurrenceCount + 1
        )
    }
}

enum CompatibilityState: String, Codable, Sendable {
    case ready
    case degraded
    case unverifiedSystem
    case blocked
}

enum CompatibilityCheckStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

struct CompatibilityCheck: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: CompatibilityCheckStatus
    let detail: String
}

struct CompatibilityReport: Codable, Sendable {
    let systemVersion: String
    let systemBuild: String
    let architecture: String
    let appVersion: String
    let state: CompatibilityState
    let checks: [CompatibilityCheck]
    let issues: [UserFacingIssue]
}

struct DiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let issue: UserFacingIssue
    let systemVersion: String
    let systemBuild: String
    let appVersion: String
    let createdAt: Date
}

struct DiagnosticExport: Codable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let systemVersion: String
    let systemBuild: String
    let architecture: String
    let compatibilityState: CompatibilityState
    let scannerPath: String
    let scannerAvailable: Bool
    let lastSuccessfulScan: Date?
    let monitoringState: String
    let issues: [UserFacingIssue]
    let diagnostics: [DiagnosticEvent]
}

struct AppSettings: Sendable {
    var scanMode: ScanMode = .listeners
    var refreshInterval: TimeInterval = 5
    var overlayEnabled = true
}

enum MacPortError: Error, LocalizedError, Sendable {
    case scannerMissing(path: String)
    case scannerNotExecutable(path: String)
    case processLaunchFailed(detail: String)
    case processTimedOut(seconds: TimeInterval)
    case nonZeroExit(code: Int32, stderr: String)
    case outputFormatChanged(detail: String)
    case parserFailure(detail: String)
    case unsupportedProtocol(String)
    case invalidPort(String)
    case compatibilityBlocked(detail: String)
    case databaseOpenFailed(detail: String)
    case databaseOperationFailed(detail: String)
    case exportFailed(detail: String)
    case overlayUnavailable(detail: String)

    var errorDescription: String {
        switch self {
        case .scannerMissing(let path): return "找不到扫描程序：\(path)"
        case .scannerNotExecutable(let path): return "扫描程序不可执行：\(path)"
        case .processLaunchFailed(let detail): return "无法启动扫描进程：\(detail)"
        case .processTimedOut(let seconds): return "扫描超过 \(seconds) 秒仍未完成"
        case .nonZeroExit(let code, let stderr): return "扫描进程退出码 \(code)：\(stderr)"
        case .outputFormatChanged(let detail): return "扫描输出格式变化：\(detail)"
        case .parserFailure(let detail): return "端口记录解析失败：\(detail)"
        case .unsupportedProtocol(let value): return "不支持的协议：\(value)"
        case .invalidPort(let value): return "非法端口：\(value)"
        case .compatibilityBlocked(let detail): return "系统兼容性检查失败：\(detail)"
        case .databaseOpenFailed(let detail): return "历史数据库无法打开：\(detail)"
        case .databaseOperationFailed(let detail): return "历史数据库操作失败：\(detail)"
        case .exportFailed(let detail): return "诊断导出失败：\(detail)"
        case .overlayUnavailable(let detail): return "悬浮层不可用：\(detail)"
        }
    }
}
