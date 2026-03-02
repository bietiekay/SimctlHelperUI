import Foundation

enum LocationValidationError: LocalizedError {
    case invalidLatitude(Double)
    case invalidLongitude(Double)
    case routeNeedsAtLeastTwoWaypoints
    case invalidSpeed(Double)
    case invalidUpdateValue(Double)

    var errorDescription: String? {
        switch self {
        case .invalidLatitude(let value):
            return "Invalid latitude \(value). Expected range: -90...90."
        case .invalidLongitude(let value):
            return "Invalid longitude \(value). Expected range: -180...180."
        case .routeNeedsAtLeastTwoWaypoints:
            return "A route requires at least two waypoints."
        case .invalidSpeed(let value):
            return "Invalid speed \(value). Speed must be greater than 0."
        case .invalidUpdateValue(let value):
            return "Invalid update value \(value). Value must be greater than 0."
        }
    }
}

struct GeoPoint: Codable, Identifiable, Equatable {
    let id: UUID
    var lat: Double
    var lon: Double

    init(id: UUID = UUID(), lat: Double, lon: Double) {
        self.id = id
        self.lat = lat
        self.lon = lon
    }

    func validate() throws {
        guard (-90...90).contains(lat) else {
            throw LocationValidationError.invalidLatitude(lat)
        }
        guard (-180...180).contains(lon) else {
            throw LocationValidationError.invalidLongitude(lon)
        }
    }
}

enum RouteUpdateMode: Codable, Equatable {
    case interval(seconds: Double)
    case distance(meters: Double)

    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    enum ModeType: String, Codable {
        case interval
        case distance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ModeType.self, forKey: .type)
        let value = try container.decode(Double.self, forKey: .value)

        switch type {
        case .interval:
            self = .interval(seconds: value)
        case .distance:
            self = .distance(meters: value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .interval(let seconds):
            try container.encode(ModeType.interval, forKey: .type)
            try container.encode(seconds, forKey: .value)
        case .distance(let meters):
            try container.encode(ModeType.distance, forKey: .type)
            try container.encode(meters, forKey: .value)
        }
    }
}

struct SavedLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var point: GeoPoint

    init(id: UUID = UUID(), name: String, point: GeoPoint) {
        self.id = id
        self.name = name
        self.point = point
    }

    mutating func normalizeName() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "Untitled Location"
        }
    }

    func validate() throws {
        try point.validate()
    }
}

struct SavedRoute: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var waypoints: [GeoPoint]
    var speedMetersPerSecond: Double
    var updateMode: RouteUpdateMode

    init(
        id: UUID = UUID(),
        name: String,
        waypoints: [GeoPoint],
        speedMetersPerSecond: Double = 20,
        updateMode: RouteUpdateMode = .interval(seconds: 1)
    ) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.speedMetersPerSecond = speedMetersPerSecond
        self.updateMode = updateMode
    }

    mutating func normalizeName() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "Untitled Route"
        }
    }

    func validate() throws {
        guard waypoints.count >= 2 else {
            throw LocationValidationError.routeNeedsAtLeastTwoWaypoints
        }
        for waypoint in waypoints {
            try waypoint.validate()
        }
        guard speedMetersPerSecond > 0 else {
            throw LocationValidationError.invalidSpeed(speedMetersPerSecond)
        }

        switch updateMode {
        case .interval(let seconds):
            guard seconds > 0 else {
                throw LocationValidationError.invalidUpdateValue(seconds)
            }
        case .distance(let meters):
            guard meters > 0 else {
                throw LocationValidationError.invalidUpdateValue(meters)
            }
        }
    }
}

enum PlaybackState: Equatable {
    case idle
    case running(routeID: UUID)
    case paused(routeID: UUID)
    case finished
    case failed(message: String)
}

struct LocationLibrary: Codable, Equatable {
    var locations: [SavedLocation]
    var routes: [SavedRoute]
    var defaultLocationID: UUID?

    static var `default`: LocationLibrary {
        let defaultLocation = SavedLocation(
            name: "Apple Park",
            point: GeoPoint(lat: 37.3349, lon: -122.0090)
        )

        return LocationLibrary(
            locations: [defaultLocation],
            routes: [
                SavedRoute(
                    name: "Campus Loop",
                    waypoints: [
                        GeoPoint(lat: 37.3349, lon: -122.0090),
                        GeoPoint(lat: 37.3317, lon: -122.0301),
                        GeoPoint(lat: 37.3257, lon: -122.0169)
                    ],
                    speedMetersPerSecond: 20,
                    updateMode: .interval(seconds: 1)
                )
            ],
            defaultLocationID: defaultLocation.id
        )
    }
}

enum LocationCommandBuilder {
    static func formatCoordinate(_ value: Double) -> String {
        var formatted = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)

        while formatted.last == "0", formatted.contains(".") {
            formatted.removeLast()
        }

        if formatted.last == "." {
            formatted.append("0")
        }

        return formatted
    }

    static func formatPoint(_ point: GeoPoint) -> String {
        "\(formatCoordinate(point.lat)),\(formatCoordinate(point.lon))"
    }

    static func startArguments(udid: String, route: SavedRoute) throws -> [String] {
        try route.validate()

        var arguments = ["location", udid, "start", "--speed=\(formatCoordinate(route.speedMetersPerSecond))"]

        switch route.updateMode {
        case .interval(let seconds):
            arguments.append("--interval=\(formatCoordinate(seconds))")
        case .distance(let meters):
            arguments.append("--distance=\(formatCoordinate(meters))")
        }

        arguments.append(contentsOf: route.waypoints.map { formatPoint($0) })
        return arguments
    }
}
