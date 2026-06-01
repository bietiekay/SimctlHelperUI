import Foundation

enum SimulatorLogLevel: String, CaseIterable, Codable, Identifiable {
    case debug
    case info
    case `default`
    case error
    case fault
    case unknown

    var id: String { rawValue }

    init(messageType: String?) {
        switch messageType?.lowercased() {
        case "debug":
            self = .debug
        case "info":
            self = .info
        case "default", "release":
            self = .default
        case "error":
            self = .error
        case "fault":
            self = .fault
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .debug:
            return L10n.t("Debug")
        case .info:
            return L10n.t("Info")
        case .default:
            return L10n.t("Default")
        case .error:
            return L10n.t("Error")
        case .fault:
            return L10n.t("Fault")
        case .unknown:
            return L10n.t("Unknown")
        }
    }

    var predicateLogTypes: [String] {
        switch self {
        case .debug:
            return ["debug"]
        case .info:
            return ["info"]
        case .default:
            return ["default", "release"]
        case .error:
            return ["error"]
        case .fault:
            return ["fault"]
        case .unknown:
            return []
        }
    }
}

struct SimulatorLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let simulatorUDID: String
    let simulatorName: String
    let timestamp: Date?
    let timestampText: String
    let level: SimulatorLogLevel
    let messageType: String
    let eventType: String
    let message: String
    let subsystem: String
    let category: String
    let process: String
    let processID: Int?
    let threadID: UInt64?
    let sender: String
    let senderImagePath: String
    let rawLine: String
    let rawFields: [String: String]

    var subsystemCategoryText: String {
        if subsystem.isEmpty {
            return category
        }
        if category.isEmpty {
            return subsystem
        }
        return "\(subsystem):\(category)"
    }

    var processText: String {
        if process.isEmpty, let processID {
            return "\(processID)"
        }
        if let processID {
            return "\(process) [\(processID)]"
        }
        return process
    }

    var readableLine: String {
        let timestampPart = timestampText.isEmpty ? "-" : timestampText
        let simulatorPart = simulatorName.isEmpty ? simulatorUDID : simulatorName
        let subsystemPart = subsystemCategoryText.isEmpty ? "-" : subsystemCategoryText
        let processPart = processText.isEmpty ? "-" : processText
        return "\(timestampPart) \(level.rawValue.uppercased()) [\(simulatorPart)] [\(processPart)] [\(subsystemPart)] \(message)"
    }

    var searchText: String {
        [
            timestampText,
            level.rawValue,
            simulatorName,
            simulatorUDID,
            process,
            subsystem,
            category,
            message,
            sender,
        ].joined(separator: " ")
    }
}

enum SimulatorLogParseResult: Equatable {
    case entry(SimulatorLogEntry)
    case malformed(String)
}

enum SimulatorLogParser {
    static func parseLine(
        _ line: String,
        simulatorUDID: String,
        simulatorName: String
    ) -> SimulatorLogParseResult {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return .malformed(line)
        }
        guard let data = trimmedLine.data(using: .utf8) else {
            return .malformed(line)
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let fields = object as? [String: Any] else {
                return .malformed(line)
            }

            let messageType = stringValue(fields["messageType"])
            let timestampText = stringValue(fields["timestamp"])
            let entry = SimulatorLogEntry(
                id: UUID(),
                simulatorUDID: simulatorUDID,
                simulatorName: simulatorName,
                timestamp: nil,
                timestampText: timestampText,
                level: SimulatorLogLevel(messageType: messageType),
                messageType: messageType,
                eventType: stringValue(fields["eventType"]),
                message: stringValue(fields["eventMessage"], fallback: stringValue(fields["composedMessage"])),
                subsystem: stringValue(fields["subsystem"]),
                category: stringValue(fields["category"]),
                process: processName(from: fields),
                processID: intValue(fields["processID"]),
                threadID: uint64Value(fields["threadID"]),
                sender: senderName(from: fields),
                senderImagePath: stringValue(fields["senderImagePath"]),
                rawLine: trimmedLine,
                rawFields: simpleStringFields(from: fields)
            )
            return .entry(entry)
        } catch {
            return .malformed(line)
        }
    }

    private static func processName(from fields: [String: Any]) -> String {
        if let process = fields["process"] as? String, !process.isEmpty {
            return process
        }
        let path = stringValue(fields["processImagePath"])
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func senderName(from fields: [String: Any]) -> String {
        if let sender = fields["sender"] as? String, !sender.isEmpty {
            return sender
        }
        let path = stringValue(fields["senderImagePath"])
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func simpleStringFields(from fields: [String: Any]) -> [String: String] {
        fields.reduce(into: [:]) { result, pair in
            switch pair.value {
            case let value as String:
                result[pair.key] = value
            case let value as NSNumber:
                result[pair.key] = value.stringValue
            case _ as NSNull:
                result[pair.key] = ""
            default:
                break
            }
        }
    }

    private static func stringValue(_ value: Any?, fallback: String = "") -> String {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return fallback
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            return value
        case let value as NSNumber:
            return value.uint64Value
        case let value as String:
            return UInt64(value)
        default:
            return nil
        }
    }
}

struct SimulatorLogLineBuffer {
    private var pending = ""

    nonisolated mutating func append(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        pending.append(text)
        var lines: [String] = []

        while let newlineIndex = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newlineIndex])
            lines.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            pending.removeSubrange(...newlineIndex)
        }

        return lines
    }

    nonisolated mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let line = pending
        pending.removeAll(keepingCapacity: true)
        return line
    }
}

enum SimulatorLogExporter {
    static func logText(entries: [SimulatorLogEntry]) -> String {
        entries.map(\.readableLine).joined(separator: "\n")
    }

    static func jsonData(entries: [SimulatorLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }
}
