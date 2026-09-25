import AppKit
import Foundation

struct SystemInfo: Codable, Sendable {
    let version: String
    let build: String
    let architecture: String

    static func current() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { rawBuffer in
            String(decoding: rawBuffer.bindMemory(to: UInt8.self), as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        let build = sysctlString("kern.osversion") ?? "unknown"
        return SystemInfo(version: versionString, build: build,
                          architecture: machine.isEmpty ? "unknown" : machine)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

protocol SystemInfoProviding: Sendable {
    func current() -> SystemInfo
}

struct LiveSystemInfoProvider: SystemInfoProviding {
    func current() -> SystemInfo { .current() }
}

@MainActor
final class CompatibilityChecker {
    private let scanner: PortScanner
    private let systemProvider: SystemInfoProviding
    private let appVersion: String

    init(scanner: PortScanner, systemProvider: SystemInfoProviding = LiveSystemInfoProvider(), appVersion: String) {
        self.scanner = scanner
        self.systemProvider = systemProvider
        self.appVersion = appVersion
    }

    func check() async -> CompatibilityReport {
        let system = systemProvider.current()
        var checks: [CompatibilityCheck] = []
        var issues: [UserFacingIssue] = []
        var blocked = false

        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion < 26 {
            blocked = true
            checks.append(CompatibilityCheck(id: "system-version", name: "系统版本", status: .failed,
                                             detail: "需要 macOS 26.0 或更高版本，当前为 \(system.version)"))
            issues.append(UserFacingIssue(id: UUID(), code: "SYS-001", severity: .critical,
                                          component: .system, title: "系统版本过低",
                                          reason: "当前 macOS 版本低于 MacPort 支持的最低版本。",
                                          impact: "端口监控无法启动。",
                                          suggestedAction: "升级 macOS 后重新启动 MacPort。",
                                          technicalDetail: system.version, retryable: false,
                                          occurredAt: Date(), occurrenceCount: 1))
        } else {
            checks.append(CompatibilityCheck(id: "system-version", name: "系统版本", status: .passed,
                                             detail: system.version))
        }

        let exactBaseline = system.version == "macOS 26.5.1" && system.build == "25F80"
        if exactBaseline {
            checks.append(CompatibilityCheck(id: "validated-build", name: "验证基线", status: .passed,
                                             detail: "macOS 26.5.1 / 25F80"))
        } else if !blocked {
            checks.append(CompatibilityCheck(id: "validated-build", name: "验证基线", status: .warning,
                                             detail: "当前 \(system.version) / \(system.build)，基线为 macOS 26.5.1 / 25F80"))
            issues.append(IssueFactory.unverifiedSystem(system: system))
        }

        if !system.architecture.contains("arm64") {
            blocked = true
            checks.append(CompatibilityCheck(id: "architecture", name: "CPU 架构", status: .failed,
                                             detail: "当前架构为 \(system.architecture)，首版仅支持 Apple Silicon arm64"))
            issues.append(UserFacingIssue(id: UUID(), code: "SYS-004", severity: .critical,
                                          component: .system, title: "当前 CPU 架构不受支持",
                                          reason: "MacPort 首版针对 Apple Silicon arm64 构建。",
                                          impact: "应用无法安全启动端口监控。",
                                          suggestedAction: "使用适配当前架构的 MacPort 版本。",
                                          technicalDetail: system.architecture, retryable: false,
                                          occurredAt: Date(), occurrenceCount: 1))
        } else {
            checks.append(CompatibilityCheck(id: "architecture", name: "CPU 架构", status: .passed,
                                             detail: system.architecture))
        }

        if NSScreen.screens.isEmpty {
            checks.append(CompatibilityCheck(id: "display", name: "显示器", status: .warning,
                                             detail: "当前没有可查询的显示器信息，刘海悬浮层会等待显示器可用"))
        } else {
            checks.append(CompatibilityCheck(id: "display", name: "显示器", status: .passed,
                                             detail: "发现 \(NSScreen.screens.count) 个显示器"))
        }

        let executable = scanner.executablePath
        if !FileManager.default.fileExists(atPath: executable) {
            blocked = true
            checks.append(CompatibilityCheck(id: "lsof-exists", name: "端口扫描程序", status: .failed,
                                             detail: "不存在：\(executable)"))
            issues.append(IssueFactory.make(for: MacPortError.scannerMissing(path: executable), system: system))
        } else if !FileManager.default.isExecutableFile(atPath: executable) {
            blocked = true
            checks.append(CompatibilityCheck(id: "lsof-executable", name: "端口扫描权限", status: .failed,
                                             detail: "文件不可执行：\(executable)"))
            issues.append(IssueFactory.make(for: MacPortError.scannerNotExecutable(path: executable), system: system))
        } else {
            checks.append(CompatibilityCheck(id: "lsof-exists", name: "端口扫描程序", status: .passed,
                                             detail: executable))
        }

        if !blocked {
            do {
                let snapshot = try await scanner.scan(mode: .listeners)
                if snapshot.warnings.isEmpty {
                    checks.append(CompatibilityCheck(id: "lsof-probe", name: "扫描探测", status: .passed,
                                                     detail: "成功解析 \(snapshot.records.count) 条监听记录"))
                } else {
                    checks.append(CompatibilityCheck(id: "lsof-probe", name: "扫描探测", status: .warning,
                                                     detail: "成功，但有 \(snapshot.warnings.count) 条解析警告"))
                    issues.append(IssueFactory.make(for: MacPortError.parserFailure(detail: snapshot.warnings.joined(separator: "; ")), system: system))
                }
            } catch {
                blocked = true
                checks.append(CompatibilityCheck(id: "lsof-probe", name: "扫描探测", status: .failed,
                                                 detail: error.localizedDescription))
                issues.append(IssueFactory.make(for: error, system: system))
                if !exactBaseline {
                    issues.append(UserFacingIssue(id: UUID(), code: "SYS-003", severity: .critical,
                                                  component: .compatibility,
                                                  title: "系统更新后端口监控不可用",
                                                  reason: "当前系统版本尚未验证，且启动扫描探测失败。",
                                                  impact: "自动端口监控已暂停，已有结果会标记为过期。",
                                                  suggestedAction: "检查是否有 MacPort 更新，点击重新检测并复制诊断信息。",
                                                  technicalDetail: "system=\(system.version); build=\(system.build); cause=\(error.localizedDescription)",
                                                  retryable: true, occurredAt: Date(), occurrenceCount: 1))
                }
            }
        }

        let state: CompatibilityState
        if blocked {
            state = .blocked
        } else if !issues.isEmpty {
            state = .degraded
        } else {
            state = .ready
        }
        return CompatibilityReport(systemVersion: system.version, systemBuild: system.build,
                                   architecture: system.architecture, appVersion: appVersion,
                                   state: state, checks: checks, issues: issues)
    }
}
