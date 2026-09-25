import Foundation

struct PortScanner: @unchecked Sendable {
    let executablePath: String
    let timeout: TimeInterval

    init(executablePath: String = "/usr/sbin/lsof", timeout: TimeInterval = 3) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    func scan(mode: ScanMode) async throws -> ScanSnapshot {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try Self.performScan(path: executablePath, timeout: timeout, mode: mode)
        }.value
    }

    private static func performScan(path: String, timeout: TimeInterval, mode: ScanMode) throws -> ScanSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw MacPortError.scannerMissing(path: path)
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw MacPortError.scannerNotExecutable(path: path)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-nP", "-iTCP", "-iUDP", "-a", "-F", "pcufLntPT"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw MacPortError.processLaunchFailed(detail: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw MacPortError.processTimedOut(seconds: timeout)
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw MacPortError.nonZeroExit(code: process.terminationStatus, stderr: clipped(stderr))
        }

        let parsed = try PortParser.parse(data: output)
        let records: [PortRecord]
        switch mode {
        case .listeners:
            records = parsed.records.filter(\.isListener)
        case .allConnections:
            records = parsed.records
        }

        return ScanSnapshot(scannedAt: Date(), mode: mode, records: records, warnings: parsed.warnings)
    }

    private static func clipped(_ value: String, maxLength: Int = 400) -> String {
        value.count <= maxLength ? value : String(value.prefix(maxLength)) + "…"
    }
}

struct ParseOutput: Sendable {
    let records: [PortRecord]
    let warnings: [String]
}

enum PortParser {
    private struct FileContext {
        var protocolValue: String?
        var name: String?
        var state: String?
    }

    static func parse(data: Data) throws -> ParseOutput {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return ParseOutput(records: [], warnings: []) }

        var processID: Int32?
        var processName: String?
        var userName: String?
        var file = FileContext()
        var records: [PortRecord] = []
        var warnings: [String] = []

        func flushFile() {
            guard let name = file.name else { return }
            guard let protocolValue = file.protocolValue,
                  let transport = TransportProtocol(lsofValue: protocolValue) else {
                warnings.append("未知协议或缺少协议：\(file.protocolValue ?? "<missing>")")
                file = FileContext()
                return
            }

            do {
                let endpoints = try EndpointParser.parse(name)
                guard let local = endpoints.local else {
                    warnings.append("缺少本地端点：\(clipped(name))")
                    file = FileContext()
                    return
                }
                let visibility: PortVisibility = processID == nil ? .partial : .complete
                let key = makeStableKey(protocolType: transport, local: local,
                                        remote: endpoints.remote)
                records.append(PortRecord(stableKey: key, protocolType: transport,
                                          localEndpoint: local, remoteEndpoint: endpoints.remote,
                                          state: file.state, processID: processID,
                                          processName: processName, userName: userName,
                                          visibility: visibility))
            } catch {
                warnings.append("端点解析失败：\(clipped(name))")
            }
            file = FileContext()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let code = line.first else { continue }
            let value = String(line.dropFirst())
            switch code {
            case "p":
                flushFile()
                file = FileContext()
                processID = Int32(value)
                processName = nil
                userName = nil
                if processID == nil { warnings.append("非法 PID：\(clipped(value))") }
            case "c":
                processName = value.isEmpty ? nil : value
            case "u":
                userName = value.isEmpty ? nil : value
            case "f":
                flushFile()
            case "P":
                file.protocolValue = value
            case "n":
                flushFile()
                file.name = value
            case "T":
                if value.hasPrefix("ST=") { file.state = String(value.dropFirst(3)) }
            case "L", "a", "t", "i":
                continue
            default:
                warnings.append("未知 lsof 字段：\(code)")
            }
        }
        flushFile()

        if records.isEmpty && warnings.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MacPortError.outputFormatChanged(detail: "输出中没有找到可解析的网络记录")
        }
        return ParseOutput(records: records, warnings: warnings)
    }

    private static func clipped(_ value: String, maxLength: Int = 180) -> String {
        value.count <= maxLength ? value : String(value.prefix(maxLength)) + "…"
    }

    private static func makeStableKey(protocolType: TransportProtocol, local: PortEndpoint,
                                      remote: PortEndpoint?) -> String {
        "\(protocolType.rawValue)|\(local.displayValue)|\(remote?.displayValue ?? "-")"
    }
}

struct ParsedEndpoints: Sendable {
    let local: PortEndpoint?
    let remote: PortEndpoint?
}

enum EndpointParser {
    static func parse(_ value: String) throws -> ParsedEndpoints {
        let pieces = value.components(separatedBy: "->")
        guard let local = try parseEndpoint(String(pieces[0])) else {
            throw MacPortError.parserFailure(detail: "缺少本地端点")
        }
        let remote = pieces.count == 2 ? try parseEndpoint(String(pieces[1])) : nil
        return ParsedEndpoints(local: local, remote: remote)
    }

    private static func parseEndpoint(_ value: String) throws -> PortEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        let addressPart: String
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]"), close < separator else { return nil }
            addressPart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        } else {
            addressPart = String(trimmed[..<separator])
        }
        let portValue = String(trimmed[trimmed.index(after: separator)...])
        guard let port = UInt16(portValue) else {
            if portValue == "*" { return nil }
            throw MacPortError.invalidPort(portValue)
        }
        return PortEndpoint(address: addressPart.isEmpty ? "*" : addressPart, port: port)
    }
}
