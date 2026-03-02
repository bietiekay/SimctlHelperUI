import Foundation
import Combine

@MainActor
final class LocationPlayerViewModel: ObservableObject {
    @Published var deviceName: String
    @Published var udid: String
    @Published var deviceState: DeviceState = .shutdown
    @Published var locations: [SavedLocation] = []
    @Published var routes: [SavedRoute] = []
    @Published var selectedLocationID: UUID?
    @Published var selectedRouteID: UUID?
    @Published var defaultLocationID: UUID?
    @Published var playbackState: PlaybackState = .idle
    @Published var errorMessage: String?

    private let service: SimctlLocationControlling
    private let libraryStore: LocationLibraryStore
    private var pollTask: Task<Void, Never>?
    private var loaded = false

    init(
        udid: String,
        initialDeviceName: String? = nil,
        service: SimctlLocationControlling,
        libraryStore: LocationLibraryStore
    ) {
        self.udid = udid
        self.deviceName = initialDeviceName ?? udid
        self.service = service
        self.libraryStore = libraryStore

        do {
            let library = try libraryStore.load()
            self.locations = library.locations
            self.routes = library.routes
            self.defaultLocationID = library.defaultLocationID ?? library.locations.first?.id
            self.selectedLocationID = library.locations.first?.id
            self.selectedRouteID = nil
        } catch {
            let fallback = LocationLibrary.default
            self.locations = fallback.locations
            self.routes = fallback.routes
            self.defaultLocationID = fallback.defaultLocationID ?? fallback.locations.first?.id
            self.selectedLocationID = fallback.locations.first?.id
            self.selectedRouteID = nil
            self.errorMessage = error.localizedDescription
        }
    }

    convenience init(udid: String, initialDeviceName: String? = nil) {
        self.init(
            udid: udid,
            initialDeviceName: initialDeviceName,
            service: SimctlService.shared,
            libraryStore: .shared
        )
    }

    deinit {
        pollTask?.cancel()
    }

    var selectedLocationIndex: Int? {
        guard let selectedLocationID else { return nil }
        return locations.firstIndex(where: { $0.id == selectedLocationID })
    }

    var selectedRouteIndex: Int? {
        guard let selectedRouteID else { return nil }
        return routes.firstIndex(where: { $0.id == selectedRouteID })
    }

    var isDeviceBooted: Bool {
        deviceState == .booted
    }

    var canStopRoute: Bool {
        switch playbackState {
        case .idle:
            return false
        default:
            return true
        }
    }

    var hasRunningSession: Bool {
        switch playbackState {
        case .running, .paused:
            return true
        default:
            return false
        }
    }

    func start() {
        guard !loaded else { return }
        loaded = true

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshDeviceStatus()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.refreshDeviceStatus()
            }
        }
    }

    func handleWindowClose() {
        Task { [weak self] in
            guard let self else { return }
            await self.service.stopRoute(udid: self.udid)
        }
    }

    func refreshDeviceStatus() async {
        do {
            async let state = service.deviceBootState(udid: udid)
            async let name = service.deviceName(udid: udid)
            let resolvedState = try await state
            let resolvedName = try await name

            deviceState = resolvedState
            deviceName = resolvedName
            playbackState = service.playbackState(udid: udid)

            if resolvedState != .booted, hasRunningSession {
                await service.stopRoute(udid: udid)
                playbackState = service.playbackState(udid: udid)
                errorMessage = "The simulator is no longer booted. Playback was stopped."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveLibrary() {
        do {
            try libraryStore.save(
                LocationLibrary(
                    locations: locations,
                    routes: routes,
                    defaultLocationID: defaultLocationID
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectLocation(_ id: UUID?) {
        selectedLocationID = id
        if id != nil {
            selectedRouteID = nil
        }
    }

    func selectRoute(_ id: UUID?) {
        selectedRouteID = id
        if id != nil {
            selectedLocationID = nil
        }
    }

    func addLocation() {
        let location = SavedLocation(name: "New Location", point: GeoPoint(lat: 0, lon: 0))
        locations.append(location)
        if defaultLocationID == nil {
            defaultLocationID = location.id
        }
        selectLocation(location.id)
        saveLibrary()
    }

    func deleteSelectedLocation() {
        guard let selectedLocationID else { return }
        locations.removeAll { $0.id == selectedLocationID }
        if defaultLocationID == selectedLocationID {
            defaultLocationID = locations.first?.id
        }
        self.selectedLocationID = locations.first?.id
        saveLibrary()
    }

    func addRoute() {
        let route = SavedRoute(
            name: "New Route",
            waypoints: [
                GeoPoint(lat: 0, lon: 0),
                GeoPoint(lat: 0.001, lon: 0.001)
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )
        routes.append(route)
        selectRoute(route.id)
        saveLibrary()
    }

    func deleteSelectedRoute() {
        guard let selectedRouteID else { return }
        routes.removeAll { $0.id == selectedRouteID }
        self.selectedRouteID = routes.first?.id
        if self.selectedRouteID == nil {
            self.selectedLocationID = locations.first?.id
        }
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

    func applySelectedLocation() {
        guard let index = selectedLocationIndex else {
            errorMessage = "Select a location first."
            return
        }

        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.locations[index].validate()
                try await self.service.setLocation(udid: self.udid, point: self.locations[index].point)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func playSelectedRoute() {
        guard let index = selectedRouteIndex else {
            errorMessage = "Select a route first."
            return
        }

        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try self.routes[index].validate()
                try await self.service.startRoute(udid: self.udid, route: self.routes[index])
                self.playbackState = self.service.playbackState(udid: self.udid)
            } catch {
                self.errorMessage = error.localizedDescription
                self.playbackState = .failed(message: error.localizedDescription)
            }
        }
    }

    func importRoute(from fileURL: URL) {
        errorMessage = nil

        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let route = try GPXRouteImporter.importRoute(from: fileURL)
            routes.append(route)
            selectRoute(route.id)
            saveLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var defaultLocationName: String {
        guard let defaultLocationID,
              let location = locations.first(where: { $0.id == defaultLocationID }) else {
            return "None"
        }
        return location.name
    }

    func setDefaultLocationToSelection() {
        guard let selectedLocationID else {
            errorMessage = "Select a location first."
            return
        }
        defaultLocationID = selectedLocationID
        saveLibrary()
    }

    func resetToDefaultLocation() {
        guard let defaultLocationID,
              let location = locations.first(where: { $0.id == defaultLocationID }) else {
            errorMessage = "No default location configured."
            return
        }

        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try location.validate()
                try await self.service.setLocation(udid: self.udid, point: location.point)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func togglePauseResume() {
        errorMessage = nil

        do {
            switch playbackState {
            case .running:
                try service.pauseRoute(udid: udid)
            case .paused:
                try service.resumeRoute(udid: udid)
            default:
                errorMessage = "No active route to pause or resume."
            }
            playbackState = service.playbackState(udid: udid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            await self.service.stopRoute(udid: self.udid)
            self.playbackState = self.service.playbackState(udid: self.udid)
        }
    }
}
