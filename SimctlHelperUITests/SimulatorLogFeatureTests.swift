import XCTest
@testable import SimctlHelperUI

@MainActor
final class SimulatorLogFeatureTests: XCTestCase {
    func testParserDecodesNDJSONLogLine() throws {
        let result = SimulatorLogParser.parseLine(
            Self.sampleLine(
                messageType: "Debug",
                subsystem: "com.miataru.ios",
                category: "Debug",
                message: "Route started"
            ),
            simulatorUDID: "DEVICE-UDID",
            simulatorName: "iPhone 17"
        )

        guard case .entry(let entry) = result else {
            XCTFail("Expected parsed log entry")
            return
        }

        XCTAssertEqual(entry.simulatorUDID, "DEVICE-UDID")
        XCTAssertEqual(entry.simulatorName, "iPhone 17")
        XCTAssertEqual(entry.level, .debug)
        XCTAssertEqual(entry.message, "Route started")
        XCTAssertEqual(entry.subsystem, "com.miataru.ios")
        XCTAssertEqual(entry.category, "Debug")
        XCTAssertEqual(entry.process, "ExampleApp")
        XCTAssertEqual(entry.processID, 123)
        XCTAssertEqual(entry.threadID, 456)
        XCTAssertEqual(entry.sender, "ExampleApp")
        XCTAssertNotNil(entry.timestamp)
    }

    func testParserTreatsMalformedLineAsNonFatal() {
        let result = SimulatorLogParser.parseLine(
            "not-json",
            simulatorUDID: "DEVICE-UDID",
            simulatorName: "iPhone 17"
        )

        XCTAssertEqual(result, .malformed("not-json"))
    }

    func testLineBufferReturnsCompleteLinesAcrossChunks() {
        var buffer = SimulatorLogLineBuffer()

        let first = buffer.append(Data("one\nt".utf8))
        let second = buffer.append(Data("wo\nthree".utf8))

        XCTAssertEqual(first, ["one"])
        XCTAssertEqual(second, ["two"])
        XCTAssertEqual(buffer.flush(), "three")
    }

    func testStoreDiscoversSubsystemsAndFiltersEntries() {
        let store = SimulatorLogStore(streamService: .shared)
        store.ingestLine(
            Self.sampleLine(messageType: "Info", subsystem: "com.example.app", category: "Debug", message: "hello"),
            udid: "DEVICE-UDID",
            deviceName: "iPhone 17"
        )
        store.ingestLine(
            Self.sampleLine(messageType: "Error", subsystem: "com.apple.network", category: "Connection", message: "timeout"),
            udid: "DEVICE-UDID",
            deviceName: "iPhone 17"
        )

        XCTAssertEqual(store.discoveredSubsystems, ["com.apple.network", "com.example.app"])

        store.selectedLevels = [.error]
        XCTAssertEqual(store.filteredEntries.map(\.message), ["timeout"])

        store.selectedLevels = Set(SimulatorLogLevel.allCases)
        store.selectedSubsystems = ["com.example.app"]
        XCTAssertEqual(store.filteredEntries.map(\.message), ["hello"])

        store.searchText = "missing"
        XCTAssertTrue(store.filteredEntries.isEmpty)
    }

    func testStoreRecordsMalformedDiagnostics() {
        let store = SimulatorLogStore(streamService: .shared)

        store.ingestLine("not-json", udid: "DEVICE-UDID", deviceName: "iPhone 17")

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.diagnostics.count, 1)
        XCTAssertTrue(store.diagnostics[0].contains("Malformed log line"))
    }

    func testStoreTrimsRingBuffer() {
        let store = SimulatorLogStore(streamService: .shared)

        for index in 0..<(SimulatorLogStore.maxEntryCount + 3) {
            store.appendEntry(Self.entry(message: "message-\(index)"))
        }

        XCTAssertEqual(store.entries.count, SimulatorLogStore.maxEntryCount)
        XCTAssertEqual(store.entries.first?.message, "message-3")
        XCTAssertEqual(store.entries.last?.message, "message-\(SimulatorLogStore.maxEntryCount + 2)")
    }

    func testExportersWriteLogAndJSON() throws {
        let result = SimulatorLogParser.parseLine(
            Self.sampleLine(messageType: "Fault", subsystem: "com.example.app", category: "Debug", message: "full message"),
            simulatorUDID: "DEVICE-UDID",
            simulatorName: "iPhone 17"
        )
        guard case .entry(let entry) = result else {
            XCTFail("Expected parsed log entry")
            return
        }

        let logText = SimulatorLogExporter.logText(entries: [entry])
        XCTAssertTrue(logText.contains("FAULT"))
        XCTAssertTrue(logText.contains("full message"))
        XCTAssertTrue(logText.contains("com.example.app:Debug"))

        let jsonData = try SimulatorLogExporter.jsonData(entries: [entry])
        let jsonText = String(decoding: jsonData, as: UTF8.self)
        XCTAssertTrue(jsonText.contains("\"message\" : \"full message\""))
        XCTAssertTrue(jsonText.contains("\"subsystem\" : \"com.example.app\""))
        XCTAssertTrue(jsonText.contains("\"rawLine\""))
    }

    private static func sampleLine(
        messageType: String,
        subsystem: String,
        category: String,
        message: String
    ) -> String {
        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"timezoneName":"","messageType":"\(messageType)","eventType":"logEvent","source":null,"formatString":"%{public}s","userID":501,"activityIdentifier":0,"subsystem":"\(subsystem)","category":"\(category)","threadID":456,"senderImageUUID":"C989E3E8-092C-3BCA-8402-88F787B4A952","bootUUID":"","processImagePath":"\\/Applications\\/ExampleApp.app\\/ExampleApp","senderImagePath":"\\/Applications\\/ExampleApp.app\\/ExampleApp","timestamp":"2026-06-01 19:39:05.537840+0200","machTimestamp":33966115338080,"eventMessage":"\(escapedMessage)","processImageUUID":"0CE9AAA6-7282-3923-B74D-7A1CAD26B8F8","traceID":3169743378388877828,"processID":123,"senderProgramCounter":1115872,"parentActivityIdentifier":0}
        """
    }

    private static func entry(message: String) -> SimulatorLogEntry {
        SimulatorLogEntry(
            id: UUID(),
            simulatorUDID: "DEVICE-UDID",
            simulatorName: "iPhone 17",
            timestamp: nil,
            timestampText: "2026-06-01 19:39:05.537840+0200",
            level: .info,
            messageType: "Info",
            eventType: "logEvent",
            message: message,
            subsystem: "com.example.app",
            category: "Debug",
            process: "ExampleApp",
            processID: 123,
            threadID: 456,
            sender: "ExampleApp",
            senderImagePath: "/Applications/ExampleApp.app/ExampleApp",
            rawLine: "{}",
            rawFields: [:]
        )
    }
}
