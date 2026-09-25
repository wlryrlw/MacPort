import AppKit
import SwiftUI

struct IssueBanner: View {
    let issue: UserFacingIssue
    let onRetry: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: issue.severity.rank >= 2 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(issue.severity.rank >= 2 ? .red : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title).font(.headline)
                    Text(issue.reason).font(.subheadline)
                }
                Spacer()
            }
            Text("影响：\(issue.impact)").font(.caption).foregroundStyle(.secondary)
            Text("建议：\(issue.suggestedAction)").font(.caption)
            HStack {
                Text(issue.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if issue.retryable {
                    Button("重新检测", action: onRetry).buttonStyle(.bordered)
                }
                Button("复制诊断", action: onCopy).buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.red.opacity(issue.severity.rank >= 2 ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DashboardView: View {
    @ObservedObject var runtime: RuntimeController
    @State private var showHistory = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var copied = false

    private var primaryIssue: UserFacingIssue? { runtime.activeIssues.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let issue = primaryIssue {
                IssueBanner(issue: issue,
                            onRetry: { Task { await runtime.runCompatibilityCheck(); await runtime.refresh() } },
                            onCopy: { Task { _ = await runtime.copyDiagnostics(); copied = true } })
            }
            controls
            statusSummary
            if runtime.monitoringState == .stale(lastSuccessfulScan: runtime.lastSuccessfulScan ?? .distantPast), let date = runtime.lastSuccessfulScan {
                Label("以下数据来自最后一次成功扫描：\(date.formatted(date: .abbreviated, time: .standard))，不能视为实时状态。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            portList
            footer
        }
        .padding(16)
        .frame(width: 470, height: 620)
        .overlay(alignment: .bottom) {
            if copied {
                Text("诊断信息已复制")
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .task {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            copied = false
                        } catch is CancellationError {
                            // The transient confirmation is intentionally cancelled when the view disappears.
                        } catch {
                            copied = false
                        }
                    }
            }
        }
        .sheet(isPresented: $showHistory) { HistoryView(runtime: runtime) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(runtime: runtime) }
        .sheet(isPresented: $showSettings) { SettingsView(runtime: runtime) }
    }

    private var header: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacPort").font(.title2.bold())
                Text("本机端口监控").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(runtime.monitoringState.displayName)
                .font(.caption.bold())
                .foregroundStyle(statusColor)
        }
    }

    private var controls: some View {
        HStack {
            Picker("扫描范围", selection: Binding(get: { runtime.settings.scanMode }, set: { value in Task { await runtime.setMode(value) } })) {
                ForEach(ScanMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Button {
                Task { await runtime.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("立即刷新")
            Button {
                runtime.togglePause()
            } label: {
                Image(systemName: runtime.monitoringState == .pausedByUser ? "play.fill" : "pause.fill")
            }
            .help(runtime.monitoringState == .pausedByUser ? "恢复扫描" : "暂停扫描")
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 18) {
            metric(title: "监听", value: runtime.records.filter(\.isListener).count, color: .green)
            metric(title: "当前连接", value: runtime.records.count, color: .blue)
            metric(title: "警告", value: runtime.activeIssues.count, color: runtime.activeIssues.isEmpty ? .secondary : .orange)
            Spacer()
        }
    }

    private func metric(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.bold()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var portList: some View {
        Group {
            if runtime.records.isEmpty {
                ContentUnavailableView {
                    Label("当前没有可见端口", systemImage: "checkmark.circle")
                } description: {
                    Text(runtime.monitoringState == .ready ? "扫描已成功完成。" : "扫描尚未成功完成，请查看上方错误信息。")
                }
            } else {
                List(runtime.records) { record in
                    PortRow(record: record)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("历史") { showHistory = true }
            Button("诊断") { showDiagnostics = true }
            Button("设置") { showSettings = true }
            Spacer()
            Text(runtime.lastSuccessfulScan.map { "最后扫描 \($0.formatted(date: .omitted, time: .standard))" } ?? "尚未成功扫描")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch runtime.monitoringState {
        case .ready: return .green
        case .readyWithWarnings: return .orange
        case .scanning, .starting: return .blue
        case .stale, .pausedByUser: return .orange
        case .failed, .pausedByCompatibilityIssue: return .red
        }
    }
}

struct PortRow: View {
    let record: PortRecord

    var body: some View {
        HStack {
            Circle().fill(record.isListener ? .green : .blue).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.protocolType.displayName)  \(record.localEndpoint.displayValue)")
                    .font(.body.monospaced())
                Text(record.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let state = record.state {
                Text(state).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct HistoryView: View {
    @ObservedObject var runtime: RuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("端口历史").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }
            if runtime.recentHistory.isEmpty {
                ContentUnavailableView("暂无历史事件", systemImage: "clock")
            } else {
                List(runtime.recentHistory) { item in
                    HStack {
                        Image(systemName: icon(for: item.eventType))
                        VStack(alignment: .leading) {
                            Text("\(item.eventType.rawValue) · 端口 \(item.localPort)")
                            Text(item.processName ?? "未知进程").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.occurredAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("清空历史") { confirmClear = true }
                    .foregroundStyle(.red)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 600, height: 480)
        .confirmationDialog("清空所有端口历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空历史", role: .destructive) { Task { await runtime.clearHistory() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作只删除本机历史事件，不影响当前端口监控。")
        }
    }

    private func icon(for type: PortEventType) -> String {
        switch type {
        case .opened: return "plus.circle"
        case .closed: return "minus.circle"
        case .stateChanged: return "arrow.triangle.2.circlepath"
        case .processChanged: return "person.crop.circle.badge.exclamationmark"
        case .visibilityChanged: return "eye"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("扫描") {
                Picker("扫描范围", selection: Binding(get: { runtime.settings.scanMode }, set: { value in Task { await runtime.setMode(value) } })) {
                    ForEach(ScanMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("刷新间隔", selection: Binding(get: { runtime.settings.refreshInterval }, set: { value in
                    runtime.setRefreshInterval(value)
                })) {
                    Text("1 秒").tag(TimeInterval(1))
                    Text("5 秒").tag(TimeInterval(5))
                    Text("15 秒").tag(TimeInterval(15))
                    Text("30 秒").tag(TimeInterval(30))
                }
            }
            Section("悬浮层") {
                Toggle("启用刘海区域摘要", isOn: Binding(get: { runtime.settings.overlayEnabled }, set: { value in
                    runtime.setOverlayEnabled(value)
                }))
                Text("没有刘海的外接显示器会回退到顶部中央区域。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 430, height: 260)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var runtime: RuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MacPort 诊断").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }
            if let report = runtime.report {
                GroupBox("兼容性") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统：\(report.systemVersion) / \(report.systemBuild)")
                        Text("架构：\(report.architecture)")
                        Text("状态：\(report.state.rawValue)")
                        ForEach(report.checks) { check in
                            Label("\(check.name)：\(check.detail)", systemImage: check.status == .failed ? "xmark.circle" : check.status == .warning ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(check.status == .failed ? .red : check.status == .warning ? .orange : .green)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !runtime.activeIssues.isEmpty {
                Text("活跃问题").font(.headline)
                List(runtime.activeIssues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(issue.code) · \(issue.title)").bold()
                        Text(issue.reason).font(.caption)
                        Text("发生 \(issue.occurrenceCount) 次").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("没有活跃错误", systemImage: "checkmark.shield")
            }
            HStack {
                Button("重新检查") { Task { await runtime.runCompatibilityCheck(); await runtime.refresh() } }
                Button("复制诊断") { Task { _ = await runtime.copyDiagnostics(); message = "已复制" } }
                Button("导出 JSON") { Task { if let url = await runtime.exportDiagnostics() { message = url.path } } }
                Spacer()
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 650, height: 560)
    }
}

struct SummaryView: View {
    @ObservedObject var runtime: RuntimeController
    let onOpenDetails: () -> Void

    var body: some View {
        Button(action: onOpenDetails) {
            HStack(spacing: 8) {
                Image(systemName: runtime.activeIssues.isEmpty ? "network" : "exclamationmark.triangle.fill")
                Text(summaryText)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(runtime.activeIssues.isEmpty ? .black.opacity(0.88) : .red.opacity(0.88), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var summaryText: String {
        if let issue = runtime.activeIssues.first { return issue.code }
        return "监听 \(runtime.records.filter(\.isListener).count) · 连接 \(runtime.records.count)"
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let runtime: RuntimeController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(runtime: RuntimeController) {
        self.runtime = runtime
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "MacPort")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DashboardView(runtime: runtime))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}
