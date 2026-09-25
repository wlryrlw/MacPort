import Foundation
import XCTest
@testable import MacPort

final class MacPortTests: XCTestCase {
    func testParsesTCPListenerAndIPv6Connection() throws {
        let fixture = """
        p1234
        cpython3
        u501
        f3
        PTCP
        n127.0.0.1:8080
        TST=LISTEN
        f4
        PTCP6
        n[::1]:8080->[::1]:51432
        TST=ESTABLISHED
        """
        let output = try PortParser.parse(data: Data(fixture.utf8))
        XCTAssertEqual(output.records.count, 2)
        XCTAssertEqual(output.records[0].localEndpoint.port, 8080)
        XCTAssertTrue(output.records[0].isListener)
        XCTAssertEqual(output.records[1].remoteEndpoint?.port, 51432)
        XCTAssertFalse(output.records[1].isListener)
    }

    func testParserRejectsUnknownNetworkRecordAsWarning() throws {
        let fixture = "p12\ncworker\nf1\nP SCTP\nn*:9\n"
        let output = try PortParser.parse(data: Data(fixture.utf8))
        XCTAssertTrue(output.records.isEmpty)
        XCTAssertFalse(output.warnings.isEmpty)
    }

    func testDiffEngineDetectsOpenChangeAndClose() {
        let firstRecord = makeRecord(port: 8080, state: "LISTEN")
        let secondRecord = makeRecord(port: 8080, state: "ESTABLISHED")
        var engine = DiffEngine()
        let first = ScanSnapshot(scannedAt: Date(timeIntervalSince1970: 1), mode: .listeners,
                                 records: [firstRecord], warnings: [])
        let second = ScanSnapshot(scannedAt: Date(timeIntervalSince1970: 2), mode: .allConnections,
                                  records: [secondRecord], warnings: [])
        let empty = ScanSnapshot(scannedAt: Date(timeIntervalSince1970: 3), mode: .allConnections,
                                 records: [], warnings: [])
        XCTAssertEqual(engine.events(for: first).map(\.type), [.opened])
        XCTAssertEqual(engine.events(for: second).map(\.type), [.stateChanged])
        XCTAssertEqual(engine.events(for: empty).map(\.type), [.closed])
    }

    func testIssueFactoryKeepsScanFailureDistinctFromEmptyResult() {
        let issue = IssueFactory.make(for: MacPortError.processTimedOut(seconds: 3))
        XCTAssertEqual(issue.code, "SCAN-003")
        XCTAssertTrue(issue.impact.contains("无效"))
    }

    func testErrorCenterDeduplicatesOccurrences() async {
        let center = ErrorCenter()
        let issue = IssueFactory.unverifiedSystem(system: SystemInfo(version: "macOS 27.0.0", build: "26A1", architecture: "arm64"))
        await center.report(issue)
        await center.report(issue)
        let current = await center.currentIssues()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.occurrenceCount, 2)
    }

    func testLiveScannerCanReadCurrentSystem() async throws {
        let snapshot = try await PortScanner(timeout: 5).scan(mode: .allConnections)
        XCTAssertEqual(snapshot.mode, .allConnections)
        XCTAssertTrue(snapshot.records.allSatisfy { $0.localEndpoint.port <= UInt16.max })
    }

    func testHistoryPersistsLifecycleEvents() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-history-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        let store = try HistoryStore(url: url)
        let record = makeRecord(port: 8080, state: "LISTEN")
        let snapshot = ScanSnapshot(scannedAt: Date(timeIntervalSince1970: 10), mode: .listeners,
                                    records: [record], warnings: [])
        let event = PortEvent(id: UUID(), occurredAt: snapshot.scannedAt, type: .opened,
                              port: record, previousValue: nil)
        try await store.record(snapshot: snapshot, events: [event])
        let history = try await store.recentEvents()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.localPort, 8080)
        XCTAssertEqual(history.first?.eventType, .opened)
    }

    private func makeRecord(port: UInt16, state: String?) -> PortRecord {
        PortRecord(stableKey: "tcp|127.0.0.1:\(port)|-|123",
                   protocolType: .tcp,
                   localEndpoint: PortEndpoint(address: "127.0.0.1", port: port),
                   remoteEndpoint: nil,
                   state: state,
                   processID: 123,
                   processName: "worker",
                   userName: "tester",
                   visibility: .complete)
    }
}
