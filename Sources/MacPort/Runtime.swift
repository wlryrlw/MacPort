import AppKit
import Foundation
import SwiftUI

@MainActor
final class RuntimeController: ObservableObject {
    @Published private(set) var monitoringState: MonitoringState = .starting
    @Published private(set) var records: [PortRecord] = []
    @Published private(set) var activeIssues: [UserFacingIssue] = []
    @Published private(set) var report: CompatibilityReport?
    @Published private(set) var lastSuccessfulScan: Date?
    @Published private(set) var recentHistory: [HistoryItem] = []
    @Published var settings = AppSettings()

    let appVersion: String
    let scanner: PortScanner
    let errorCenter: ErrorCenter
    let historyStore: HistoryStore
    let diagnosticsStore: DiagnosticsStore
    let compatibilityChecker: CompatibilityChecker

    private var diffEngine = DiffEngine()
    private var monitoringTask: Task<Void, Never>?
    private var isCompatibilityBlocked = false
    private var startupErrors: [Error] = []

    init() throws {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        scanner = PortScanner()
        errorCenter = ErrorCenter()
        let directory = try RuntimeController.applicationSupportDirectory()
        do {
            historyStore = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        } catch {
            startupErrors.append(error)
            historyStore = try HistoryStore(url: directory.appendingPathComponent("history-recovery.sqlite"))
        }
        do {
            diagnosticsStore = try DiagnosticsStore(url: directory.appendingPathComponent("diagnostics.sqlite"), appVersion: appVersion)
        } catch {
            startupErrors.append(error)
            diagnosticsStore = try DiagnosticsStore(url: directory.appendingPathComponent("diagnostics-recovery.sqlite"), appVersion: appVersion)
        }
        compatibilityChecker = CompatibilityChecker(scanner: scanner, appVersion: appVersion)
        settings.scanMode = ScanMode(rawValue: UserDefaults.standard.string(forKey: "MacPort.scanMode") ?? "") ?? .listeners
        settings.refreshInterval = UserDefaults.standard.object(forKey: "MacPort.refreshInterval") as? TimeInterval ?? 5
        settings.overlayEnabled = UserDefaults.standard.object(forKey: "MacPort.overlayEnabled") as? Bool ?? true
    }

    deinit { monitoringTask?.cancel() }

    func start() async {
        monitoringState = .starting
        for error in startupErrors {
            await reportError(error)
        }
        await runCompatibilityCheck()
        guard !isCompatibilityBlocked else {
            monitoringState = .pausedByCompatibilityIssue
            return
        }
        await refresh()
        startMonitoringLoop()
    }

    func runCompatibilityCheck() async {
        let compatibility = await compatibilityChecker.check()
        report = compatibility
        isCompatibilityBlocked = compatibility.state == .blocked
        for issue in compatibility.issues {
            await reportIssue(issue)
        }
        if compatibility.state == .ready {
            await errorCenter.resolve(code: "SYS-001")
            await errorCenter.resolve(code: "SYS-002")
            await errorCenter.resolve(code: "SYS-003")
            await errorCenter.resolve(code: "SCAN-001")
            await errorCenter.resolve(code: "SCAN-002")
            await errorCenter.resolve(code: "SCAN-006")
            await refreshIssues()
        }
        if compatibility.systemVersion != "macOS 26.5.1" || compatibility.systemBuild != "25F80" {
            let previous = UserDefaults.standard.string(forKey: "MacPort.lastSystemFingerprint")
            let current = "\(compatibility.systemVersion)|\(compatibility.systemBuild)"
            if let previous, previous != current {
                let issue = UserFacingIssue(id: UUID(), code: "SYS-002", severity: .warning,
                                            component: .compatibility, title: "检测到系统版本变化",
                                            reason: "系统从 \(previous.replacingOccurrences(of: "|", with: " / ")) 更新为 \(current.replacingOccurrences(of: "|", with: " / "))。",
                                            impact: "MacPort 已重新执行兼容性检查；当前版本尚未以此 Build 作为验证基线。",
                                            suggestedAction: "如果监控异常，请点击重新检测并复制诊断信息。",
                                            technicalDetail: "previous=\(previous); current=\(current)", retryable: true,
                                            occurredAt: Date(), occurrenceCount: 1)
                await reportIssue(issue)
            }
            UserDefaults.standard.set(current, forKey: "MacPort.lastSystemFingerprint")
        } else {
            UserDefaults.standard.set("\(compatibility.systemVersion)|\(compatibility.systemBuild)", forKey: "MacPort.lastSystemFingerprint")
        }
    }

    func refresh() async {
        guard !isCompatibilityBlocked else {
            monitoringState = .pausedByCompatibilityIssue
            return
        }
        monitoringState = .scanning
        let snapshot: ScanSnapshot
        do {
            snapshot = try await scanner.scan(mode: settings.scanMode)
        } catch {
            await reportError(error)
            if let lastSuccessfulScan {
                monitoringState = .stale(lastSuccessfulScan: lastSuccessfulScan)
            } else {
                monitoringState = .failed
            }
            await refreshIssues()
            return
        }

        let events = diffEngine.events(for: snapshot)
        records = snapshot.records.sorted {
            if $0.isListener != $1.isListener { return $0.isListener && !$1.isListener }
            if $0.localEndpoint.port != $1.localEndpoint.port { return $0.localEndpoint.port < $1.localEndpoint.port }
            return $0.displayName < $1.displayName
        }
        lastSuccessfulScan = snapshot.scannedAt

        if snapshot.warnings.isEmpty {
            await errorCenter.resolve(code: "PARSE-001")
            await errorCenter.resolve(code: "SCAN-008")
        } else {
            let issue = IssueFactory.make(for: MacPortError.parserFailure(detail: snapshot.warnings.joined(separator: "; ")))
            await reportIssue(issue)
        }

        do {
            try await historyStore.record(snapshot: snapshot, events: events)
            recentHistory = try await historyStore.recentEvents()
            await errorCenter.resolve(code: "DB-001")
            await errorCenter.resolve(code: "DB-002")
        } catch {
            await reportError(error)
        }

        monitoringState = snapshot.warnings.isEmpty ? .ready : .readyWithWarnings
        await refreshIssues()
    }

    func setMode(_ mode: ScanMode) async {
        settings.scanMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "MacPort.scanMode")
        await refresh()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        settings.refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: "MacPort.refreshInterval")
        startMonitoringLoop()
    }

    func setOverlayEnabled(_ enabled: Bool) {
        settings.overlayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "MacPort.overlayEnabled")
    }

    func togglePause() {
        if monitoringState == .pausedByUser {
            startMonitoringLoop()
            monitoringState = .ready
        } else {
            monitoringTask?.cancel()
            monitoringTask = nil
            monitoringState = .pausedByUser
        }
    }

    func clearHistory() async {
        do {
            try await historyStore.clear()
            recentHistory = []
            await errorCenter.resolve(code: "DB-002")
        } catch {
            await reportError(error)
        }
        await refreshIssues()
    }

    func copyDiagnostics() async -> String {
        let export = await makeDiagnosticExport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(export)
        } catch {
            await reportError(MacPortError.exportFailed(detail: error.localizedDescription))
            return "MacPort 诊断信息无法编码"
        }
        guard let text = String(data: data, encoding: .utf8) else {
            await reportError(MacPortError.exportFailed(detail: "诊断 JSON 不是有效 UTF-8"))
            return "MacPort 诊断信息无法编码"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    func exportDiagnostics() async -> URL? {
        let export = await makeDiagnosticExport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(export)
            let timestamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacPort-diagnostics-\(timestamp).json")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            await reportError(MacPortError.exportFailed(detail: error.localizedDescription))
            return nil
        }
    }

    private func startMonitoringLoop() {
        monitoringTask?.cancel()
        let interval = settings.refreshInterval
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private func reportError(_ error: Error) async {
        let issue = IssueFactory.make(for: error)
        await reportIssue(issue)
    }

    private func reportIssue(_ issue: UserFacingIssue) async {
        await errorCenter.report(issue)
        do {
            try await diagnosticsStore.record(issue, system: .current())
        } catch {
            let diagnosticIssue = IssueFactory.make(for: MacPortError.databaseOperationFailed(detail: "诊断记录写入失败：\(error.localizedDescription)"))
            await errorCenter.report(diagnosticIssue)
        }
        await refreshIssues()
    }

    private func refreshIssues() async {
        activeIssues = await errorCenter.currentIssues()
    }

    private func makeDiagnosticExport() async -> DiagnosticExport {
        let system = SystemInfo.current()
        let diagnostics: [DiagnosticEvent]
        do {
            diagnostics = try await diagnosticsStore.recent()
        } catch {
            await reportError(error)
            diagnostics = []
        }
        return DiagnosticExport(generatedAt: Date(), appVersion: appVersion,
                                systemVersion: system.version, systemBuild: system.build,
                                architecture: system.architecture,
                                compatibilityState: report?.state ?? .blocked,
                                scannerPath: scanner.executablePath,
                                scannerAvailable: FileManager.default.isExecutableFile(atPath: scanner.executablePath),
                                lastSuccessfulScan: lastSuccessfulScan,
                                monitoringState: monitoringState.displayName,
                                issues: activeIssues, diagnostics: diagnostics)
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("MacPort", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
