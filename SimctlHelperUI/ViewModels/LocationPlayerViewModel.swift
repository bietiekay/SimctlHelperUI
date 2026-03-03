import Foundation
import Combine

@MainActor
final class LocationPlayerViewModel: ObservableObject {
    @Published var deviceName: String
    @Published var udid: String
    @Published var deviceState: DeviceState = .shutdown
    @Published var availableDevices: [SimDevice] = []
    @Published var autoBootOnSend: Bool = true
    @Published var locations: [SavedLocation] = []
    @Published var routes: [SavedRoute] = []
    @Published var selectedLocationID: UUID?
    @Published var selectedRouteID: UUID?
    @Published var defaultLocationID: UUID?
    @Published var playbackState: PlaybackState = .idle
    @Published var errorMessage: String?
    @Published var debugLogText: String = ""

    private let service: SimctlLocationControlling
    private let libraryStore: LocationLibraryStore
    private var pollTask: Task<Void, Never>?
    private var loaded = false
    private var debugLogObserver: NSObjectProtocol?

    init(
        udid: String? = nil,
        initialDeviceName: String? = nil,
        service: SimctlLocationControlling,
        libraryStore: LocationLibraryStore
    ) {
        let resolvedUDID = udid ?? ""
        self.udid = resolvedUDID
        self.deviceName = initialDeviceName ?? (resolvedUDID.isEmpty ? "No simulator selected" : resolvedUDID)
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

        debugLogText = RouteDebugLogStore.shared.snapshot()
        debugLogObserver = NotificationCenter.default.addObserver(
            forName: .routeDebugLogDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.debugLogText = RouteDebugLogStore.shared.snapshot()
            }
        }
        logDebug("Initialized view model for udid=\(resolvedUDID.isEmpty ? "<none>" : resolvedUDID)")
    }

    convenience init(udid: String? = nil, initialDeviceName: String? = nil) {
        self.init(
            udid: udid,
            initialDeviceName: initialDeviceName,
            service: SimctlService.shared,
            libraryStore: .shared
        )
    }

    deinit {
        pollTask?.cancel()
        if let debugLogObserver {
            NotificationCenter.default.removeObserver(debugLogObserver)
        }
    }

    private func logDebug(_ message: String) {
        RouteDebugLogStore.shared.log("LocationPlayerViewModel: \(message)")
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

    var hasTargetDevice: Bool {
        !udid.isEmpty
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
        logDebug("start() called, beginning status polling for udid=\(udid)")

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
        logDebug("handleWindowClose() called for udid=\(udid)")
        Task { [weak self] in
            guard let self, self.hasTargetDevice else { return }
            await self.service.stopRoute(udid: self.udid)
            self.logDebug("Window close stopRoute finished for udid=\(self.udid)")
        }
    }

    func selectTargetDevice(_ selectedUDID: String) {
        guard !selectedUDID.isEmpty else { return }
        guard udid != selectedUDID else { return }
        logDebug("Switching target device from \(udid) to \(selectedUDID)")

        udid = selectedUDID
        if let selected = availableDevices.first(where: { $0.udid == selectedUDID }) {
            deviceName = selected.name
            deviceState = selected.state
        }
        playbackState = service.playbackState(udid: selectedUDID)
        errorMessage = nil
    }

    func refreshDeviceStatus() async {
        do {
            let response = try await service.fetchDeviceList()
            var flattenedDevices: [SimDevice] = []
            for deviceList in response.devices.values {
                flattenedDevices.append(contentsOf: deviceList)
            }
            flattenedDevices.sort { lhs, rhs in
                if lhs.isBooted != rhs.isBooted {
                    return lhs.isBooted && !rhs.isBooted
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            availableDevices = flattenedDevices

            if udid.isEmpty || !flattenedDevices.contains(where: { $0.udid == udid }) {
                if let fallback = flattenedDevices.first(where: { $0.isBooted }) ?? flattenedDevices.first {
                    udid = fallback.udid
                } else {
                    udid = ""
                    deviceName = "No simulator selected"
                    deviceState = .shutdown
                    playbackState = .idle
                    return
                }
            }

            guard let selected = flattenedDevices.first(where: { $0.udid == udid }) else {
                deviceName = "No simulator selected"
                deviceState = .shutdown
                playbackState = .idle
                return
            }

            deviceName = selected.name
            deviceState = selected.state
            playbackState = service.playbackState(udid: udid)

            if selected.state != .booted, hasRunningSession {
                await service.stopRoute(udid: udid)
                playbackState = service.playbackState(udid: udid)
                errorMessage = "The simulator is no longer booted. Playback was stopped."
                logDebug("Stopped playback because simulator is no longer booted (udid=\(udid))")
            }
        } catch {
            errorMessage = error.localizedDescription
            logDebug("refreshDeviceStatus failed for udid=\(udid): \(error.localizedDescription)")
        }
    }

    private func ensureTargetDeviceBootedForSend() async throws {
        logDebug("ensureTargetDeviceBootedForSend() start for udid=\(udid), isBooted=\(isDeviceBooted), autoBoot=\(autoBootOnSend)")
        guard hasTargetDevice else {
            throw SimctlError.commandFailed("Select a target simulator in the Location Player first.")
        }

        guard !isDeviceBooted else { return }

        guard autoBootOnSend else {
            throw SimctlError.commandFailed("Selected simulator is shutdown. Enable Auto-Boot or boot it manually.")
        }

        do {
            try await service.bootDevice(udid: udid)
            logDebug("bootDevice command sent for udid=\(udid)")
        } catch {
            // Boot may race with an already in-progress boot. Verify state before failing.
            await refreshDeviceStatus()
            if !isDeviceBooted {
                logDebug("bootDevice failed and simulator is still not booted for udid=\(udid): \(error.localizedDescription)")
                throw error
            }
            logDebug("bootDevice returned error but device is already booted for udid=\(udid)")
        }

        let bootDeadline = Date().addingTimeInterval(30)
        while Date() < bootDeadline {
            await refreshDeviceStatus()
            if isDeviceBooted {
                logDebug("Simulator boot confirmed for udid=\(udid)")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        logDebug("Boot timeout reached for udid=\(udid)")
        throw SimctlError.commandFailed("Failed to boot selected simulator within timeout.")
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

    func exportLibraryData() -> Data? {
        do {
            return try libraryStore.encodeLibrary(
                LocationLibrary(
                    locations: locations,
                    routes: routes,
                    defaultLocationID: defaultLocationID
                )
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importLibrary(from fileURL: URL) -> LocationLibrary? {
        errorMessage = nil

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
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importSelection(locationIDs: Set<UUID>, routeIDs: Set<UUID>, from library: LocationLibrary) {
        var importedLocations = 0
        var importedRoutes = 0
        var skippedLocations = 0
        var skippedRoutes = 0
        var importedLocationIDs: [UUID] = []
        var importedRouteIDs: [UUID] = []

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
                importedLocationIDs.append(normalized.id)
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
                importedRouteIDs.append(normalized.id)
                importedRoutes += 1
            } catch {
                skippedRoutes += 1
            }
        }

        if defaultLocationID == nil {
            defaultLocationID = locations.first?.id
        }

        if let firstImportedRouteID = importedRouteIDs.first {
            selectedRouteID = firstImportedRouteID
            selectedLocationID = nil
        } else if let firstImportedLocationID = importedLocationIDs.first {
            selectedLocationID = firstImportedLocationID
            selectedRouteID = nil
        } else {
            selectedLocationID = locations.first?.id
            selectedRouteID = nil
        }

        saveLibrary()
        if skippedLocations + skippedRoutes > 0 {
            errorMessage = "Imported \(importedLocations) location(s), \(importedRoutes) route(s). Skipped \(skippedLocations + skippedRoutes) invalid item(s)."
        } else {
            errorMessage = nil
        }
    }

    func selectLocation(_ id: UUID?) {
        logDebug("selectLocation(\(id?.uuidString ?? "nil"))")
        selectedLocationID = id
        if id != nil {
            selectedRouteID = nil
        }
    }

    func selectRoute(_ id: UUID?) {
        logDebug("selectRoute(\(id?.uuidString ?? "nil"))")
        selectedRouteID = id
        if id != nil {
            selectedLocationID = nil
        }
    }

    @discardableResult
    func addLocation(at point: GeoPoint) -> UUID {
        let location = SavedLocation(name: "New Location", point: point)
        locations.append(location)
        if defaultLocationID == nil {
            defaultLocationID = location.id
        }
        selectLocation(location.id)
        saveLibrary()
        return location.id
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
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        guard let index = selectedLocationIndex else {
            errorMessage = "Select a location first."
            return
        }

        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                self.logDebug("applySelectedLocation() start for udid=\(self.udid), locationID=\(self.locations[index].id)")
                try await self.ensureTargetDeviceBootedForSend()
                try self.locations[index].validate()
                try await self.service.setLocation(udid: self.udid, point: self.locations[index].point)
                self.logDebug("applySelectedLocation() success for udid=\(self.udid), locationID=\(self.locations[index].id)")
            } catch {
                self.errorMessage = error.localizedDescription
                self.logDebug("applySelectedLocation() failed for udid=\(self.udid): \(error.localizedDescription)")
            }
        }
    }

    func playSelectedRoute() {
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        guard let index = selectedRouteIndex else {
            errorMessage = "Select a route first."
            return
        }

        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                self.logDebug(
                    """
                    playSelectedRoute() start for udid=\(self.udid), routeID=\(self.routes[index].id), \
                    waypoints=\(self.routes[index].waypoints.count), mode=\(self.routes[index].updateMode)
                    """
                )
                try await self.ensureTargetDeviceBootedForSend()
                try self.routes[index].validate()
                self.playbackState = .running(routeID: self.routes[index].id)
                try await self.service.startRoute(udid: self.udid, route: self.routes[index])
                self.playbackState = self.service.playbackState(udid: self.udid)
                self.logDebug("playSelectedRoute() command accepted; playbackState=\(self.playbackState)")
            } catch {
                self.errorMessage = error.localizedDescription
                self.playbackState = .failed(message: error.localizedDescription)
                self.logDebug("playSelectedRoute() failed: \(error.localizedDescription)")
            }
        }
    }

    func importRoute(from fileURL: URL) {
        guard let preview = prepareGPXImport(from: fileURL) else { return }
        importRoute(from: preview)
    }

    func prepareGPXImport(from fileURL: URL) -> GPXImportPreview? {
        errorMessage = nil

        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return try GPXRouteImporter.preview(from: fileURL)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importRoute(
        from preview: GPXImportPreview,
        selectedTimeRange: ClosedRange<Date>? = nil,
        selectedPointRange: ClosedRange<Int>? = nil
    ) {
        errorMessage = nil

        do {
            let route = try preview.route(
                selectedTimeRange: selectedTimeRange,
                selectedPointRange: selectedPointRange
            )
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
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        guard let defaultLocationID,
              let location = locations.first(where: { $0.id == defaultLocationID }) else {
            errorMessage = "No default location configured."
            return
        }

        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try location.validate()
                try await self.service.setLocation(udid: self.udid, point: location.point)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func clearAppliedLocation() {
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try await self.service.clearLocation(udid: self.udid)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func togglePauseResume() {
        errorMessage = nil
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        let currentState = service.playbackState(udid: udid)
        playbackState = currentState
        logDebug("togglePauseResume() called for udid=\(udid), currentState=\(currentState)")

        do {
            switch currentState {
            case .running:
                try service.pauseRoute(udid: udid)
            case .paused:
                try service.resumeRoute(udid: udid)
            default:
                errorMessage = "No active route to pause or resume."
            }
            playbackState = service.playbackState(udid: udid)
            logDebug("togglePauseResume() success for udid=\(udid), newState=\(playbackState)")
        } catch {
            errorMessage = error.localizedDescription
            logDebug("togglePauseResume() failed for udid=\(udid): \(error.localizedDescription)")
        }
    }

    func stop() {
        errorMessage = nil
        guard hasTargetDevice else {
            errorMessage = "Select a target simulator first."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            self.logDebug("stop() requested for udid=\(self.udid)")
            await self.service.stopRoute(udid: self.udid)
            self.playbackState = self.service.playbackState(udid: self.udid)
            self.logDebug("stop() finished for udid=\(self.udid), newState=\(self.playbackState)")
        }
    }

    var debugLogLineCount: Int {
        guard !debugLogText.isEmpty else { return 0 }
        return debugLogText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var debugLogShareText: String {
        let header = "SimctlHelperUI Debug Log\nDevice: \(deviceName)\nUDID: \(udid)\n-----\n"
        if debugLogText.isEmpty {
            return "\(header)(empty)"
        }
        return "\(header)\(debugLogText)"
    }

    func clearDebugLog() {
        RouteDebugLogStore.shared.clear()
        logDebug("Debug log cleared by user")
    }

    func refreshDebugLog() {
        debugLogText = RouteDebugLogStore.shared.snapshot()
    }
}
