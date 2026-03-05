import Foundation

enum GPXImportError: LocalizedError, Equatable {
    case unreadable
    case invalidFormat(String)
    case noRoutePoints
    case noRoutePointsInSelection

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return L10n.t("The GPX file could not be read.")
        case .invalidFormat(let message):
            return L10n.f("Invalid GPX format: %@", message)
        case .noRoutePoints:
            return L10n.t("No route points found. The GPX must contain at least two track/route points.")
        case .noRoutePointsInSelection:
            return L10n.t("No route points found in the selected time range.")
        }
    }
}

struct GPXTimestampedPoint: Identifiable, Equatable {
    let id: UUID
    let point: GeoPoint
    let timestamp: Date?

    init(id: UUID = UUID(), point: GeoPoint, timestamp: Date?) {
        self.id = id
        self.point = point
        self.timestamp = timestamp
    }
}

struct GPXImportPreview: Equatable {
    let name: String
    let points: [GPXTimestampedPoint]

    var totalPointCount: Int {
        points.count
    }

    var timeRange: ClosedRange<Date>? {
        let timestamps = points.compactMap(\.timestamp)
        guard let minDate = timestamps.min(),
              let maxDate = timestamps.max(),
              minDate < maxDate else {
            return nil
        }
        return minDate...maxDate
    }

    var canSelectTimeRange: Bool {
        timeRange != nil
    }

    func points(in selectedTimeRange: ClosedRange<Date>) -> [GPXTimestampedPoint] {
        points.filter { point in
            guard let timestamp = point.timestamp else { return false }
            return selectedTimeRange.contains(timestamp)
        }
    }

    func points(in selectedPointRange: ClosedRange<Int>) -> [GPXTimestampedPoint] {
        guard !points.isEmpty else { return [] }
        let lowerBound = max(0, min(points.count - 1, selectedPointRange.lowerBound))
        let upperBound = max(lowerBound, min(points.count - 1, selectedPointRange.upperBound))
        return Array(points[lowerBound...upperBound])
    }

    func route() throws -> SavedRoute {
        try route(selectedTimeRange: nil, selectedPointRange: nil)
    }

    func route(selectedTimeRange: ClosedRange<Date>) throws -> SavedRoute {
        try route(selectedTimeRange: selectedTimeRange, selectedPointRange: nil)
    }

    func route(selectedPointRange: ClosedRange<Int>) throws -> SavedRoute {
        try route(selectedTimeRange: nil, selectedPointRange: selectedPointRange)
    }

    func route(
        selectedTimeRange: ClosedRange<Date>?,
        selectedPointRange: ClosedRange<Int>?
    ) throws -> SavedRoute {
        let resolvedWaypoints: [GeoPoint]
        if let selectedTimeRange {
            resolvedWaypoints = points(in: selectedTimeRange).map(\.point)
            guard resolvedWaypoints.count >= 2 else {
                throw GPXImportError.noRoutePointsInSelection
            }
        } else if let selectedPointRange {
            resolvedWaypoints = points(in: selectedPointRange).map(\.point)
            guard resolvedWaypoints.count >= 2 else {
                throw GPXImportError.noRoutePointsInSelection
            }
        } else {
            resolvedWaypoints = points.map(\.point)
        }

        guard resolvedWaypoints.count >= 2 else {
            throw GPXImportError.noRoutePoints
        }

        return SavedRoute(
            name: name,
            waypoints: resolvedWaypoints,
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )
    }
}

enum GPXRouteImporter {
    static func preview(from fileURL: URL) throws -> GPXImportPreview {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GPXImportError.unreadable
        }

        return try preview(from: data, fallbackName: fileURL.deletingPathExtension().lastPathComponent)
    }

    static func preview(from data: Data, fallbackName: String) throws -> GPXImportPreview {
        let parserDelegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Unknown XML parsing error"
            throw GPXImportError.invalidFormat(message)
        }

        guard parserDelegate.points.count >= 2 else {
            throw GPXImportError.noRoutePoints
        }

        let routeName = parserDelegate.routeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (routeName?.isEmpty == false ? routeName! : fallbackName)
        return GPXImportPreview(name: resolvedName, points: parserDelegate.points)
    }

    static func importRoute(from fileURL: URL) throws -> SavedRoute {
        try preview(from: fileURL).route()
    }

    static func importRoute(from data: Data, fallbackName: String) throws -> SavedRoute {
        try preview(from: data, fallbackName: fallbackName).route()
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private(set) var points: [GPXTimestampedPoint] = []
    private(set) var routeName: String?

    private var elementStack: [String] = []
    private var currentText = ""
    private var currentPoint: ParsedPoint?

    private let dateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private struct ParsedPoint {
        var lat: Double
        var lon: Double
        var timestamp: Date?
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        currentText = ""

        if elementName == "trkpt" || elementName == "rtept" {
            guard let latValue = attributeDict["lat"],
                  let lonValue = attributeDict["lon"],
                  let lat = Double(latValue),
                  let lon = Double(lonValue) else {
                return
            }

            currentPoint = ParsedPoint(lat: lat, lon: lon, timestamp: nil)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            _ = elementStack.popLast()
            currentText = ""
        }

        if elementName == "time",
           let parent = elementStack.dropLast().last,
           (parent == "trkpt" || parent == "rtept"),
           var currentPoint {
            currentPoint.timestamp = parseDate(from: currentText)
            self.currentPoint = currentPoint
            return
        }

        if elementName == "trkpt" || elementName == "rtept" {
            if let currentPoint {
                points.append(
                    GPXTimestampedPoint(
                        point: GeoPoint(lat: currentPoint.lat, lon: currentPoint.lon),
                        timestamp: currentPoint.timestamp
                    )
                )
            }
            currentPoint = nil
            return
        }

        guard elementName == "name", routeName == nil else {
            return
        }

        // Prefer names attached to route/track metadata.
        let parent = elementStack.dropLast().last
        guard parent == "trk" || parent == "rte" || parent == "metadata" else {
            return
        }

        let normalized = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            routeName = normalized
        }
    }

    private func parseDate(from rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let withFractional = dateFormatterWithFractionalSeconds.date(from: value) {
            return withFractional
        }
        return dateFormatter.date(from: value)
    }
}
