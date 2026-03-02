import Foundation

enum GPXImportError: LocalizedError {
    case unreadable
    case invalidFormat(String)
    case noRoutePoints

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The GPX file could not be read."
        case .invalidFormat(let message):
            return "Invalid GPX format: \(message)"
        case .noRoutePoints:
            return "No route points found. The GPX must contain at least two track/route points."
        }
    }
}

enum GPXRouteImporter {
    static func importRoute(from fileURL: URL) throws -> SavedRoute {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GPXImportError.unreadable
        }

        return try importRoute(from: data, fallbackName: fileURL.deletingPathExtension().lastPathComponent)
    }

    static func importRoute(from data: Data, fallbackName: String) throws -> SavedRoute {
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

        return SavedRoute(
            name: resolvedName,
            waypoints: parserDelegate.points,
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private(set) var points: [GeoPoint] = []
    private(set) var routeName: String?

    private var elementStack: [String] = []
    private var currentText = ""

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

            points.append(GeoPoint(lat: lat, lon: lon))
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
}
