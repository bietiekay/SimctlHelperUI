import Foundation
import Combine
import AppKit

@MainActor
final class LocationPlayerViewModel: ObservableObject {
    @Published private(set) var deviceName: String
    @Published private(set) var targetUDID: String
    @Published private(set) var deviceState: DeviceState = .shutdown
    @Published var autoBootOnSend: Bool {
        didSet {
            UserDefaults.standard.set(autoBootOnSend, forKey: Self.autoBootPreferenceKey)
        }
    }
    @Published private(set) var locations: [SavedLocation] = []
    @Published private(set) var routes: [SavedRoute] = []
    @Published var selectedLocationID: UUID?
    @Published var selectedRouteID: UUID?
    @Published private(set) var defaultLocationID: UUID?
    @Published var playbackState: PlaybackState = .idle
    @Published var feedback: FeedbackMessage?

    private let service: SimctlLocationControlling
    private let deviceStore: DeviceStore
    private let libraryController: LocationLibraryController
    private var cancellables: Set<AnyCancellable> = []
    private var loaded = false

    init(
        targetUDID: String? = nil,
        deviceStore: DeviceStore,
        libraryController: LocationLibraryController,
        service: SimctlLocationControlling
    ) {
        let resolvedUDID = (targetUDID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetUDID = resolvedUDID
        self.deviceStore = deviceStore
        self.libraryController = libraryController
        self.service = service
        self.autoBootOnSend = UserDefaults.standard.object(forKey: Self.autoBootPreferenceKey) as? Bool ?? true
        self.locations = libraryController.locations
        self.routes = libraryController.routes
        self.defaultLocationID = libraryController.defaultLocationID
        self.selectedLocationID = libraryController.locations.first?.id
        self.deviceName = resolvedUDID.isEmpty ? L10n.t("No simulator selected") : resolvedUDID

        bindStores()
        syncDeviceFromStore()
        syncSelections()
    }

    convenience init(
        targetUDID: String? = nil,
        deviceStore: DeviceStore,
        libraryController: LocationLibraryController
    ) {
        self.init(
            targetUDID: targetUDID,
            deviceStore: deviceStore,
            libraryController: libraryController,
            service: SimctlService.shared
        )
    }

    convenience init(
        udid: String? = nil,
        initialDeviceName _: String? = nil,
        service: SimctlLocationControlling,
        libraryStore: LocationLibraryStore
    ) {
        let libraryController = Self.testSupportLibraryController(for: libraryStore)
        self.init(
            targetUDID: udid,
            deviceStore: Self.testSupportDeviceStore,
            libraryController: libraryController,
            service: service
        )
    }

    convenience init(udid: String? = nil, initialDeviceName _: String? = nil) {
        self.init(
            targetUDID: udid,
            deviceStore: .shared,
            libraryController: .shared
        )
    }

    var hasTargetDevice: Bool {
        !targetUDID.isEmpty
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

    var defaultLocationName: String {
        libraryController.defaultLocationName
    }

    func start() {
        guard !loaded else { return }
        loaded = true

        Task { [weak self] in
            await self?.refreshDeviceStatus()
        }
    }

    func refreshDeviceStatus() async {
        await deviceStore.refreshDevices(showLoadingIndicator: false, preserveFeedback: true)
        syncDeviceFromStore()
        if hasTargetDevice {
            playbackState = service.playbackState(udid: targetUDID)
        } else {
            playbackState = .idle
        }
    }

    func handleCloseRequest() -> Bool {
        guard hasRunningSession else { return true }

        let alert = NSAlert()
        alert.messageText = L10n.t("Route playback is still running.")
        alert.informativeText = L10n.t("Choose whether playback should continue in the background or stop before closing this window.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("Keep Running and Close"))
        alert.addButton(withTitle: L10n.t("Stop Route and Close"))
        alert.addButton(withTitle: L10n.t("Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            stop()
            return true
        default:
            return false
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

    @discardableResult
    func addLocation(at point: GeoPoint) -> UUID {
        let location = libraryController.addLocation(at: point)
        syncFromLibraryController()
        selectLocation(location.id)
        return location.id
    }

    func deleteSelectedLocation() {
        guard let selectedLocationID else { return }
        libraryController.deleteLocation(id: selectedLocationID)
        syncFromLibraryController()
        syncSelections()
    }

    func addRoute() {
        let route = libraryController.addRoute()
        syncFromLibraryController()
        selectRoute(route.id)
    }

    func deleteSelectedRoute() {
        guard let selectedRouteID else { return }
        libraryController.deleteRoute(id: selectedRouteID)
        syncFromLibraryController()
        syncSelections()
    }

    func replaceLocation(_ location: SavedLocation) {
        libraryController.replaceLocation(location)
        syncFromLibraryController()
    }

    func replaceRoute(_ route: SavedRoute) {
        libraryController.replaceRoute(route)
        syncFromLibraryController()
    }

    func renameLocation(id: UUID, to newName: String) {
        guard var location = locations.first(where: { $0.id == id }) else { return }
        location.name = newName
        replaceLocation(location)
    }

    func renameRoute(id: UUID, to newName: String) {
        guard var route = routes.first(where: { $0.id == id }) else { return }
        route.name = newName
        replaceRoute(route)
    }

    func exportLibraryData() -> Data? {
        libraryController.exportLibraryData()
    }

    func importLibrary(from fileURL: URL) -> LocationLibrary? {
        libraryController.importLibrary(from: fileURL)
    }

    func importSelection(locationIDs: Set<UUID>, routeIDs: Set<UUID>, from library: LocationLibrary) {
        libraryController.importSelection(locationIDs: locationIDs, routeIDs: routeIDs, from: library)
        syncFromLibraryController()
    }

    func prepareGPXImport(from fileURL: URL) -> GPXImportPreview? {
        libraryController.prepareGPXImport(from: fileURL)
    }

    @discardableResult
    func importRoute(
        from preview: GPXImportPreview,
        selectedTimeRange: ClosedRange<Date>? = nil,
        selectedPointRange: ClosedRange<Int>? = nil
    ) -> SavedRoute? {
        let route = libraryController.importRoute(
            from: preview,
            selectedTimeRange: selectedTimeRange,
            selectedPointRange: selectedPointRange
        )
        syncFromLibraryController()
        return route
    }

    func setDefaultLocationToSelection() {
        guard let selectedLocationID else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a location first."))
            return
        }
        libraryController.setDefaultLocation(id: selectedLocationID)
        syncFromLibraryController()
    }

    func applySelectedLocation() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        guard let location = selectedLocation else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a location first."))
            return
        }

        feedback = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try location.validate()
                try await self.service.setLocation(udid: self.targetUDID, point: location.point)
                self.playbackState = self.service.playbackState(udid: self.targetUDID)
                self.feedback = FeedbackMessage(level: .success, text: L10n.t("Location sent to simulator."))
            } catch {
                self.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    func playSelectedRoute() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        guard let route = selectedRoute else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a route first."))
            return
        }

        feedback = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try route.validate()
                self.playbackState = .running(routeID: route.id)
                try await self.service.startRoute(udid: self.targetUDID, route: route)
                self.playbackState = self.service.playbackState(udid: self.targetUDID)
                self.feedback = FeedbackMessage(level: .success, text: L10n.f("Started route \"%@\".", route.name))
            } catch {
                self.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
                self.playbackState = .failed(message: error.localizedDescription)
            }
        }
    }

    func resetToDefaultLocation() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        guard let defaultLocationID,
              let location = locations.first(where: { $0.id == defaultLocationID }) else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("No default location configured."))
            return
        }

        feedback = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try location.validate()
                try await self.service.setLocation(udid: self.targetUDID, point: location.point)
                self.feedback = FeedbackMessage(level: .success, text: L10n.t("Default location sent to simulator."))
            } catch {
                self.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    func clearAppliedLocation() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        feedback = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTargetDeviceBootedForSend()
                try await self.service.clearLocation(udid: self.targetUDID)
                self.feedback = FeedbackMessage(level: .success, text: L10n.t("Cleared simulated location."))
            } catch {
                self.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    func togglePauseResume() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        let currentState = service.playbackState(udid: targetUDID)
        playbackState = currentState

        do {
            switch currentState {
            case .running:
                try service.pauseRoute(udid: targetUDID)
            case .paused:
                try service.resumeRoute(udid: targetUDID)
            default:
                feedback = FeedbackMessage(level: .warning, text: L10n.t("No active route to pause or resume."))
                return
            }
            playbackState = service.playbackState(udid: targetUDID)
            feedback = nil
        } catch {
            feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
        }
    }

    func stop() {
        guard hasTargetDevice else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Select a target simulator first."))
            return
        }

        feedback = nil

        Task { [weak self] in
            guard let self else { return }
            await self.service.stopRoute(udid: self.targetUDID)
            self.playbackState = self.service.playbackState(udid: self.targetUDID)
        }
    }

    func clearFeedback() {
        feedback = nil
        deviceStore.clearFeedback()
        libraryController.clearFeedback()
    }

    private var selectedLocation: SavedLocation? {
        guard let selectedLocationID else { return nil }
        return locations.first(where: { $0.id == selectedLocationID })
    }

    private var selectedRoute: SavedRoute? {
        guard let selectedRouteID else { return nil }
        return routes.first(where: { $0.id == selectedRouteID })
    }

    private func bindStores() {
        libraryController.$locations
            .sink { [weak self] locations in
                self?.locations = locations
                self?.syncSelections()
            }
            .store(in: &cancellables)

        libraryController.$routes
            .sink { [weak self] routes in
                self?.routes = routes
                self?.syncSelections()
            }
            .store(in: &cancellables)

        libraryController.$defaultLocationID
            .sink { [weak self] defaultLocationID in
                self?.defaultLocationID = defaultLocationID
            }
            .store(in: &cancellables)

        libraryController.$feedback
            .sink { [weak self] feedback in
                guard let feedback else { return }
                self?.feedback = feedback
            }
            .store(in: &cancellables)

        deviceStore.$devices
            .sink { [weak self] _ in
                self?.syncDeviceFromStore()
            }
            .store(in: &cancellables)

        deviceStore.$feedback
            .sink { [weak self] feedback in
                guard let feedback else { return }
                self?.feedback = feedback
            }
            .store(in: &cancellables)
    }

    private func syncFromLibraryController() {
        locations = libraryController.locations
        routes = libraryController.routes
        defaultLocationID = libraryController.defaultLocationID
    }

    private func syncSelections() {
        if let selectedRouteID,
           routes.contains(where: { $0.id == selectedRouteID }) {
            return
        }

        if let selectedLocationID,
           locations.contains(where: { $0.id == selectedLocationID }) {
            return
        }

        if let firstLocationID = locations.first?.id {
            selectedLocationID = firstLocationID
            selectedRouteID = nil
            return
        }

        if let firstRouteID = routes.first?.id {
            selectedRouteID = firstRouteID
            selectedLocationID = nil
            return
        }

        selectedLocationID = nil
        selectedRouteID = nil
    }

    private func syncDeviceFromStore() {
        guard hasTargetDevice else {
            deviceName = L10n.t("No simulator selected")
            deviceState = .shutdown
            playbackState = .idle
            return
        }

        guard let device = deviceStore.device(for: targetUDID) else {
            deviceName = L10n.t("Missing simulator")
            deviceState = .shutdown
            playbackState = .idle
            return
        }

        deviceName = device.name
        deviceState = device.state
        playbackState = service.playbackState(udid: targetUDID)
    }

    private func ensureTargetDeviceBootedForSend() async throws {
        guard hasTargetDevice else {
            throw SimctlError.commandFailed(L10n.t("Select a target simulator in the Location Simulation window first."))
        }

        guard !isDeviceBooted else { return }

        guard autoBootOnSend else {
            throw SimctlError.commandFailed(L10n.t("Selected simulator is shutdown. Enable Auto-Boot in Options or boot it manually."))
        }

        do {
            try await service.bootDevice(udid: targetUDID)
        } catch {
            await refreshDeviceStatus()
            if !isDeviceBooted {
                throw error
            }
        }

        let bootDeadline = Date().addingTimeInterval(30)
        while Date() < bootDeadline {
            await refreshDeviceStatus()
            if isDeviceBooted {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw SimctlError.commandFailed(L10n.t("Failed to boot selected simulator within timeout."))
    }

    private static let autoBootPreferenceKey = "autoBootOnSend"
    private static let testSupportDeviceStore = DeviceStore(autoload: false)
    private nonisolated(unsafe) static var testSupportLibraryControllers: [String: LocationLibraryController] = [:]

    private static func testSupportLibraryController(for libraryStore: LocationLibraryStore) -> LocationLibraryController {
        let key = libraryStore.storageIdentifier
        if let controller = testSupportLibraryControllers[key] {
            return controller
        }

        let controller = LocationLibraryController(libraryStore: libraryStore)
        testSupportLibraryControllers[key] = controller
        return controller
    }
}
