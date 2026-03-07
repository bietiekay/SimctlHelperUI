import Foundation
import Combine

@MainActor
final class LocationLibraryController: ObservableObject {
    static let shared = LocationLibraryController()

    @Published private(set) var locations: [SavedLocation] = []
    @Published private(set) var routes: [SavedRoute] = []
    @Published private(set) var defaultLocationID: UUID?
    @Published var feedback: FeedbackMessage?

    private let libraryStore: LocationLibraryStore

    init(libraryStore: LocationLibraryStore = .shared) {
        self.libraryStore = libraryStore

        do {
            let library = try libraryStore.load()
            locations = library.locations
            routes = library.routes
            defaultLocationID = library.defaultLocationID ?? library.locations.first?.id
        } catch {
            let fallback = LocationLibrary.default
            locations = fallback.locations
            routes = fallback.routes
            defaultLocationID = fallback.defaultLocationID ?? fallback.locations.first?.id
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
        }
    }

    var defaultLocationName: String {
        guard let defaultLocationID,
              let location = locations.first(where: { $0.id == defaultLocationID }) else {
            return L10n.t("None")
        }
        return location.name
    }

    func exportLibraryData() -> Data? {
        do {
            return try libraryStore.encodeLibrary(currentLibrary)
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            return nil
        }
    }

    func importLibrary(from fileURL: URL) -> LocationLibrary? {
        feedback = nil

        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try libraryStore.decodeLibrary(from: data)
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            return nil
        }
    }

    func importSelection(locationIDs: Set<UUID>, routeIDs: Set<UUID>, from library: LocationLibrary) {
        var importedLocations = 0
        var importedRoutes = 0
        var skippedLocations = 0
        var skippedRoutes = 0

        var existingLocationIDs = Set(locations.map(\.id))
        var existingRouteIDs = Set(routes.map(\.id))

        for location in library.locations where locationIDs.contains(location.id) {
            do {
                var normalized = location
                normalized.normalizeName()
                try normalized.validate()
                if existingLocationIDs.contains(normalized.id) {
                    normalized = SavedLocation(id: UUID(), name: normalized.name, point: normalized.point)
                }
                existingLocationIDs.insert(normalized.id)
                locations.append(normalized)
                importedLocations += 1
            } catch {
                skippedLocations += 1
            }
        }

        for route in library.routes where routeIDs.contains(route.id) {
            do {
                var normalized = route
                normalized.normalizeName()
                try normalized.validate()
                if existingRouteIDs.contains(normalized.id) {
                    normalized = SavedRoute(
                        id: UUID(),
                        name: normalized.name,
                        waypoints: normalized.waypoints,
                        speedMetersPerSecond: normalized.speedMetersPerSecond,
                        updateMode: normalized.updateMode
                    )
                }
                existingRouteIDs.insert(normalized.id)
                routes.append(normalized)
                importedRoutes += 1
            } catch {
                skippedRoutes += 1
            }
        }

        if defaultLocationID == nil {
            defaultLocationID = locations.first?.id
        }

        saveLibrary()

        let skippedCount = skippedLocations + skippedRoutes
        if skippedCount > 0 {
            feedback = FeedbackMessage(
                level: .warning,
                text: L10n.f(
                    "Imported %d location(s), %d route(s). Skipped %d invalid item(s).",
                    importedLocations,
                    importedRoutes,
                    skippedCount
                )
            )
        } else {
            feedback = FeedbackMessage(
                level: .success,
                text: L10n.f(
                    "Imported %d location(s) and %d route(s).",
                    importedLocations,
                    importedRoutes
                )
            )
        }
    }

    func prepareGPXImport(from fileURL: URL) -> GPXImportPreview? {
        feedback = nil

        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return try GPXRouteImporter.preview(from: fileURL)
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            return nil
        }
    }

    func importRoute(
        from preview: GPXImportPreview,
        selectedTimeRange: ClosedRange<Date>? = nil,
        selectedPointRange: ClosedRange<Int>? = nil
    ) -> SavedRoute? {
        do {
            let route = try preview.route(
                selectedTimeRange: selectedTimeRange,
                selectedPointRange: selectedPointRange
            )
            routes.append(route)
            saveLibrary()
            feedback = FeedbackMessage(level: .success, text: L10n.f("Imported route \"%@\".", route.name))
            return route
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func addLocation(at point: GeoPoint) -> SavedLocation {
        let location = SavedLocation(name: L10n.t("New Location"), point: point)
        locations.append(location)
        if defaultLocationID == nil {
            defaultLocationID = location.id
        }
        saveLibrary()
        return location
    }

    func deleteLocation(id: UUID) {
        locations.removeAll { $0.id == id }
        if defaultLocationID == id {
            defaultLocationID = locations.first?.id
        }
        saveLibrary()
    }

    @discardableResult
    func addRoute() -> SavedRoute {
        let route = SavedRoute(
            name: L10n.t("New Route"),
            waypoints: [
                GeoPoint(lat: 0, lon: 0),
                GeoPoint(lat: 0.001, lon: 0.001),
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )
        routes.append(route)
        saveLibrary()
        return route
    }

    func deleteRoute(id: UUID) {
        routes.removeAll { $0.id == id }
        saveLibrary()
    }

    func replaceLocation(_ location: SavedLocation) {
        guard let index = locations.firstIndex(where: { $0.id == location.id }) else { return }
        var normalized = location
        normalized.normalizeName()
        locations[index] = normalized
        saveLibrary()
    }

    func replaceRoute(_ route: SavedRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        var normalized = route
        normalized.normalizeName()
        routes[index] = normalized
        saveLibrary()
    }

    func setDefaultLocation(id: UUID) {
        defaultLocationID = id
        saveLibrary()
    }

    func clearFeedback() {
        feedback = nil
    }

    private var currentLibrary: LocationLibrary {
        LocationLibrary(
            locations: locations,
            routes: routes,
            defaultLocationID: defaultLocationID
        )
    }

    private func saveLibrary() {
        do {
            try libraryStore.save(currentLibrary)
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
        }
    }
}
