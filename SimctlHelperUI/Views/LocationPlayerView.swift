import SwiftUI
import UniformTypeIdentifiers
import MapKit
import AppKit

struct LocationPlayerView: View {
    private enum FileImportKind {
        case gpx
        case library
    }

    @StateObject var viewModel: LocationPlayerViewModel
    @State private var activeFileImportKind: FileImportKind?
    @State private var isFileImporterPresented = false
    @State private var showLibraryExporter = false
    @State private var librarySelection: LibrarySelection?
    @State private var locationDraft: SavedLocation?
    @State private var routeDraft: SavedRoute?
    @State private var isSyncingSelection = false
    @State private var libraryExportDocument = LocationLibraryTransferDocument(data: Data())
    @State private var pendingLocationSaveTask: Task<Void, Never>?
    @State private var pendingRouteSaveTask: Task<Void, Never>?
    @State private var locationSimulationWindowIdentifier: String?
    @State private var owningWindow: NSWindow?

    private let inlineWaypointEditingLimit = 20
    private let mapWaypointEditingLimit = 3_000

    private var allowedImportContentTypes: [UTType] {
        switch activeFileImportKind {
        case .gpx:
            let gpxType = UTType(filenameExtension: "gpx") ?? .xml
            return [gpxType, .xml]
        case .library:
            return [.json]
        case .none:
            return [.data]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let feedback = viewModel.feedback {
                HStack(spacing: 10) {
                    FeedbackBannerView(message: feedback)
                    Button {
                        viewModel.clearFeedback()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            headerView
            Divider()

            HSplitView {
                libraryPanel
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

                detailPanel
                    .frame(minWidth: 520, maxWidth: .infinity)
            }
            .layoutPriority(1)

            Divider()
            playbackControls
        }
        .frame(
            minWidth: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.width,
            minHeight: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.height
        )
        .navigationTitle(L10n.f("Location Simulation - %@", viewModel.deviceName))
        .background(Color(NSColor.windowBackgroundColor))
        .background(
            WindowObserverView { window in
                DispatchQueue.main.async {
                    resolveOwningWindow(window)
                }
            }
        )
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.t("Refresh")) {
                    Task {
                        await viewModel.refreshDeviceStatus()
                    }
                }

                Menu {
                    Toggle(L10n.t("Auto-Boot on Send"), isOn: $viewModel.autoBootOnSend)
                } label: {
                    Label(L10n.t("Options"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .focusedSceneValue(
            \.libraryMenuActions,
            LibraryMenuActions(
                importGPXRoute: { beginGPXRouteImport() },
                importLibraryJSON: { beginLibraryImport() },
                exportLibraryJSON: { beginLibraryExport() }
            )
        )
        .onAppear {
            viewModel.start()
            ensureLibrarySelection()
            syncSelectionFromViewModel()
        }
        .onChange(of: librarySelection) { _, value in
            guard !isSyncingSelection else { return }
            switch value {
            case .location(let id):
                viewModel.selectLocation(id)
            case .route(let id):
                viewModel.selectRoute(id)
            case .none:
                viewModel.selectLocation(nil)
                viewModel.selectRoute(nil)
            }
            syncLocationDraft()
            syncRouteDraft()
        }
        .onChange(of: viewModel.selectedLocationID) { _, value in
            guard value != librarySelection?.locationID else { return }
            syncSelectionFromViewModel()
        }
        .onChange(of: viewModel.selectedRouteID) { _, value in
            guard value != librarySelection?.routeID else { return }
            syncSelectionFromViewModel()
        }
        .onChange(of: viewModel.locations) { _, _ in
            ensureLibrarySelection()
            syncLocationDraft()
        }
        .onChange(of: viewModel.routes) { _, _ in
            ensureLibrarySelection()
            syncRouteDraft()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedImportContentTypes,
            allowsMultipleSelection: false
        ) { result in
            let importKind = activeFileImportKind
            activeFileImportKind = nil

            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else { return }
                switch importKind {
                case .gpx:
                    guard let preview = viewModel.prepareGPXImport(from: fileURL) else { return }
                    openGPXPreviewWindow(preview: preview)
                case .library:
                    guard let importedLibrary = viewModel.importLibrary(from: fileURL) else { return }
                    openLibraryImportSelectionWindow(library: importedLibrary)
                case .none:
                    break
                }
            case .failure(let error):
                viewModel.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $showLibraryExporter,
            document: libraryExportDocument,
            contentType: .json,
            defaultFilename: libraryExportFilename
        ) { result in
            if case .failure(let error) = result {
                viewModel.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func resolveOwningWindow(_ window: NSWindow) {
        locationSimulationWindowIdentifier = window.identifier?.rawValue
        owningWindow = window
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.deviceName)
                        .font(.title3.weight(.semibold))
                    Text(L10n.t("This window is bound to a single simulator."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isDeviceBooted ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isDeviceBooted ? L10n.t("Booted") : L10n.t("Shutdown"))
                        .font(.callout)
                        .foregroundStyle(viewModel.isDeviceBooted ? .primary : .secondary)
                }
            }

            HStack(spacing: 12) {
                Text(L10n.f("UDID: %@", viewModel.targetUDID))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(L10n.f("Default: %@", viewModel.defaultLocationName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()
            }
        }
        .padding(16)
    }

    private var libraryPanel: some View {
        List(selection: $librarySelection) {
            Section {
                ForEach(viewModel.locations) { location in
                    HStack {
                        Text(location.name)
                        Spacer()
                        if viewModel.defaultLocationID == location.id {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        locationContextMenu(for: location)
                    }
                    .tag(LibrarySelection.location(location.id))
                }
            } header: {
                HStack {
                    Text(L10n.t("Locations"))
                    Spacer()
                    Button {
                        openLocationMapPicker()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("Add"))
                }
            }

            Section {
                ForEach(viewModel.routes) { route in
                    Text(route.name)
                        .contentShape(Rectangle())
                        .contextMenu {
                            routeContextMenu(for: route)
                        }
                        .tag(LibrarySelection.route(route.id))
                }
            } header: {
                HStack {
                    Text(L10n.t("Routes"))
                    Spacer()
                    Button {
                        viewModel.addRoute()
                        syncSelectionFromViewModel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("Add"))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch librarySelection {
                case .location:
                    if let locationDraft {
                        locationDetails(location: locationDraft)
                    } else {
                        Text(L10n.t("Select a location from the library."))
                            .foregroundStyle(.secondary)
                    }
                case .route:
                    if let routeDraft {
                        routeDetails(route: routeDraft)
                    } else {
                        Text(L10n.t("Select a route from the library."))
                            .foregroundStyle(.secondary)
                    }
                case .none:
                    Text(L10n.t("Select a location or route from the library."))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func locationDetails(location: SavedLocation) -> some View {
        let previewPoint = locationDraft?.point ?? location.point
        let previewName = locationDraft?.name ?? location.name
        let previewLocationID = locationDraft?.id ?? location.id

        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Location Details"))
                .font(.headline)

            TextField(L10n.t("Name"), text: Binding(
                get: { locationDraft?.name ?? "" },
                set: { value in
                    updateLocationDraft { $0.name = value }
                }
            ))

            HStack(spacing: 12) {
                TextField(L10n.t("Latitude"), value: Binding(
                    get: { locationDraft?.point.lat ?? location.point.lat },
                    set: { value in
                        updateLocationDraft { $0.point.lat = value }
                    }
                ), format: .number.precision(.fractionLength(1...8)))

                TextField(L10n.t("Longitude"), value: Binding(
                    get: { locationDraft?.point.lon ?? location.point.lon },
                    set: { value in
                        updateLocationDraft { $0.point.lon = value }
                    }
                ), format: .number.precision(.fractionLength(1...8)))
            }

            Button(L10n.t("Edit On Map")) {
                openLocationEditMapPicker(location)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Preview"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                LocationPreviewMap(locationID: previewLocationID, point: previewPoint, title: previewName)
                    .frame(minHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(
                    String(
                        format: L10n.t("Lat %.6f, Lon %.6f"),
                        locale: Locale.current,
                        previewPoint.lat,
                        previewPoint.lon
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func routeDetails(route: SavedRoute) -> some View {
        let waypoints = routeDraft?.waypoints ?? route.waypoints
        let directlyVisibleWaypoints = Array(waypoints.prefix(inlineWaypointEditingLimit))
        let hiddenWaypointCount = max(0, waypoints.count - directlyVisibleWaypoints.count)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Route Details"))
                .font(.headline)

            HStack {
                Text(L10n.t("Name"))
                    .frame(width: 120, alignment: .leading)
                TextField(L10n.t("Route Name"), text: Binding(
                    get: { routeDraft?.name ?? route.name },
                    set: { value in
                        updateRouteDraft { $0.name = value }
                    }
                ))
            }

            HStack {
                Text(L10n.t("Speed (m/s)"))
                    .frame(width: 120, alignment: .leading)
                TextField("20.0", value: Binding(
                    get: { routeDraft?.speedMetersPerSecond ?? route.speedMetersPerSecond },
                    set: { value in
                        updateRouteDraft { $0.speedMetersPerSecond = value }
                    }
                ), format: .number.precision(.fractionLength(1...4)))
            }

            Picker(L10n.t("Update Mode"), selection: Binding(
                get: {
                    guard let routeDraft else { return 0 }
                    switch routeDraft.updateMode {
                    case .interval:
                        return 0
                    case .distance:
                        return 1
                    }
                },
                set: { selection in
                    updateRouteDraft { route in
                        route.updateMode = selection == 0 ? .interval(seconds: 1) : .distance(meters: 10)
                    }
                }
            )) {
                Text(L10n.t("Interval")).tag(0)
                Text(L10n.t("Distance")).tag(1)
            }
            .pickerStyle(.segmented)

            Group {
                if case .interval(let seconds) = routeDraft?.updateMode ?? route.updateMode {
                    HStack {
                        Text(L10n.t("Interval (s)"))
                            .frame(width: 120, alignment: .leading)
                        TextField("1.0", value: Binding(
                            get: { seconds },
                            set: { value in
                                updateRouteDraft { $0.updateMode = .interval(seconds: value) }
                            }
                        ), format: .number.precision(.fractionLength(1...4)))
                    }
                }

                if case .distance(let meters) = routeDraft?.updateMode ?? route.updateMode {
                    HStack {
                        Text(L10n.t("Distance (m)"))
                            .frame(width: 120, alignment: .leading)
                        TextField("10.0", value: Binding(
                            get: { meters },
                            set: { value in
                                updateRouteDraft { $0.updateMode = .distance(meters: value) }
                            }
                        ), format: .number.precision(.fractionLength(1...4)))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.f("Waypoints (%d)", waypoints.count))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button(L10n.t("Edit On Map")) {
                        openWaypointMapPicker()
                    }
                }

                if hiddenWaypointCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.f("Direct edit is limited to the first %d waypoints.", inlineWaypointEditingLimit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let first = waypoints.first, let last = waypoints.last {
                            Text(
                                String(
                                    format: L10n.t("Start: %.6f, %.6f  |  End: %.6f, %.6f"),
                                    locale: Locale.current,
                                    first.lat, first.lon, last.lat, last.lon
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        Text(L10n.f("+ %d additional waypoints hidden in direct editor.", hiddenWaypointCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(directlyVisibleWaypoints) { waypoint in
                    HStack(spacing: 8) {
                        TextField(L10n.t("Lat"), value: Binding(
                            get: { waypointLatitude(for: waypoint.id) ?? waypoint.lat },
                            set: { value in
                                updateRouteDraft { draft in
                                    guard let index = draft.waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
                                    draft.waypoints[index].lat = value
                                }
                            }
                        ), format: .number.precision(.fractionLength(1...8)))

                        TextField(L10n.t("Lon"), value: Binding(
                            get: { waypointLongitude(for: waypoint.id) ?? waypoint.lon },
                            set: { value in
                                updateRouteDraft { draft in
                                    guard let index = draft.waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
                                    draft.waypoints[index].lon = value
                                }
                            }
                        ), format: .number.precision(.fractionLength(1...8)))

                        Button(role: .destructive) {
                            updateRouteDraft { draft in
                                draft.waypoints.removeAll { $0.id == waypoint.id }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.hasTargetDevice {
                Text(L10n.t("No target simulator selected."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !viewModel.isDeviceBooted, viewModel.autoBootOnSend {
                Text(L10n.t("Selected simulator is shutdown. Actions will boot it automatically."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !viewModel.isDeviceBooted {
                Text(L10n.t("Selected simulator is shutdown."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isRouteSelection {
                HStack {
                    Button(L10n.t("Set Location")) {
                        flushLocationDraftSave()
                        viewModel.applySelectedLocation()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!viewModel.hasTargetDevice || viewModel.selectedLocationID == nil)

                    Button(L10n.t("Clear Location")) {
                        viewModel.clearAppliedLocation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasTargetDevice)

                    Button(L10n.t("Reset To Default Location")) {
                        flushLocationDraftSave()
                        viewModel.resetToDefaultLocation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasTargetDevice || viewModel.defaultLocationID == nil)

                    Spacer()
                    Text(L10n.t("Single location mode"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button(L10n.t("Play")) {
                        flushRouteDraftSave()
                        viewModel.playSelectedRoute()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isPlayDisabled)

                    Button(pauseButtonTitle) {
                        viewModel.togglePauseResume()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPauseDisabled)

                    Button(L10n.t("Stop")) {
                        viewModel.stop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isStopDisabled)

                    Spacer()

                    Text(routeStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private var isRouteSelection: Bool {
        librarySelection?.routeID != nil
    }

    private var pauseButtonTitle: String {
        switch viewModel.playbackState {
        case .running:
            return L10n.t("Pause")
        case .paused:
            return L10n.t("Resume")
        default:
            return L10n.t("Pause/Resume")
        }
    }

    private var routeStatusText: String {
        switch viewModel.playbackState {
        case .idle:
            return L10n.t("Idle")
        case .running:
            return L10n.t("Running")
        case .paused:
            return L10n.t("Paused")
        case .finished:
            return L10n.t("Finished")
        case .failed(let message):
            return L10n.f("Failed: %@", message)
        }
    }

    private var isPlayDisabled: Bool {
        !viewModel.hasTargetDevice || viewModel.selectedRouteID == nil
    }

    private var isPauseDisabled: Bool {
        !viewModel.hasTargetDevice || !viewModel.hasRunningSession
    }

    private var isStopDisabled: Bool {
        !viewModel.hasTargetDevice || !viewModel.canStopRoute
    }

    private func ensureLibrarySelection() {
        if let selection = librarySelection {
            switch selection {
            case .location(let locationID):
                if viewModel.locations.contains(where: { $0.id == locationID }) {
                    return
                }
            case .route(let routeID):
                if viewModel.routes.contains(where: { $0.id == routeID }) {
                    return
                }
            }
        }

        if let selectedRouteID = viewModel.selectedRouteID,
           viewModel.routes.contains(where: { $0.id == selectedRouteID }) {
            librarySelection = .route(selectedRouteID)
            return
        }

        if let selectedLocationID = viewModel.selectedLocationID,
           viewModel.locations.contains(where: { $0.id == selectedLocationID }) {
            librarySelection = .location(selectedLocationID)
            return
        }

        if let firstLocationID = viewModel.locations.first?.id {
            viewModel.selectLocation(firstLocationID)
            librarySelection = .location(firstLocationID)
            return
        }

        if let firstRouteID = viewModel.routes.first?.id {
            viewModel.selectRoute(firstRouteID)
            librarySelection = .route(firstRouteID)
            return
        }

        librarySelection = nil
    }

    private func syncSelectionFromViewModel() {
        isSyncingSelection = true
        if let selectedRouteID = viewModel.selectedRouteID {
            librarySelection = .route(selectedRouteID)
        } else if let selectedLocationID = viewModel.selectedLocationID {
            librarySelection = .location(selectedLocationID)
        } else {
            librarySelection = nil
        }
        isSyncingSelection = false
        syncLocationDraft()
        syncRouteDraft()
    }

    private func syncLocationDraft() {
        guard let selectedLocationID = viewModel.selectedLocationID,
              let location = viewModel.locations.first(where: { $0.id == selectedLocationID }) else {
            locationDraft = nil
            return
        }
        locationDraft = location
    }

    private func syncRouteDraft() {
        guard let selectedRouteID = viewModel.selectedRouteID,
              let route = viewModel.routes.first(where: { $0.id == selectedRouteID }) else {
            routeDraft = nil
            return
        }
        routeDraft = route
    }

    private func updateLocationDraft(_ update: (inout SavedLocation) -> Void) {
        guard var draft = locationDraft else { return }
        update(&draft)
        locationDraft = draft
        scheduleLocationSave(for: draft)
    }

    private func updateRouteDraft(_ update: (inout SavedRoute) -> Void) {
        guard var draft = routeDraft else { return }
        update(&draft)
        routeDraft = draft
        scheduleRouteSave(for: draft)
    }

    private func scheduleLocationSave(for draft: SavedLocation) {
        pendingLocationSaveTask?.cancel()
        pendingLocationSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            viewModel.replaceLocation(draft)
        }
    }

    private func scheduleRouteSave(for draft: SavedRoute) {
        pendingRouteSaveTask?.cancel()
        pendingRouteSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            viewModel.replaceRoute(draft)
        }
    }

    private func flushLocationDraftSave() {
        pendingLocationSaveTask?.cancel()
        pendingLocationSaveTask = nil
        if let draft = locationDraft {
            viewModel.replaceLocation(draft)
        }
    }

    private func flushRouteDraftSave() {
        pendingRouteSaveTask?.cancel()
        pendingRouteSaveTask = nil
        if let draft = routeDraft {
            viewModel.replaceRoute(draft)
        }
    }

    private func waypointLatitude(for id: UUID) -> Double? {
        routeDraft?.waypoints.first(where: { $0.id == id })?.lat
    }

    private func waypointLongitude(for id: UUID) -> Double? {
        routeDraft?.waypoints.first(where: { $0.id == id })?.lon
    }

    private func openLocationMapPicker() {
        let initialPoint = locationDraft?.point
            ?? routeDraft?.waypoints.last
            ?? viewModel.locations.first?.point
            ?? GeoPoint(lat: 37.3349, lon: -122.0090)

        openCoordinatePickerWindow(
            MapPickerContext(
                mode: .addLocation,
                title: L10n.t("Choose Location Point"),
                subtitle: L10n.t("Click on the map to place the new saved location."),
                initialPoint: initialPoint,
                existingWaypoints: []
            )
        )
    }

    private func openLocationEditMapPicker(_ location: SavedLocation) {
        openCoordinatePickerWindow(
            MapPickerContext(
                mode: .editLocation(locationID: location.id),
                title: L10n.t("Edit Location Point"),
                subtitle: L10n.t("Click on the map to move this location."),
                initialPoint: location.point,
                existingWaypoints: []
            )
        )
    }

    private func openWaypointMapPicker() {
        let existingWaypoints = routeDraft?.waypoints ?? []
        guard existingWaypoints.count <= mapWaypointEditingLimit else {
            viewModel.feedback = FeedbackMessage(
                level: .warning,
                text: L10n.f(
                    "Map waypoint editor supports up to %d waypoints. Reduce route size first.",
                    mapWaypointEditingLimit
                )
            )
            return
        }

        let initialPoint = existingWaypoints.last
            ?? locationDraft?.point
            ?? viewModel.locations.first?.point
            ?? GeoPoint(lat: 37.3349, lon: -122.0090)

        openCoordinatePickerWindow(
            MapPickerContext(
                mode: .editWaypoints,
                title: L10n.t("Edit Waypoints"),
                subtitle: L10n.t("Select a waypoint to move, or add a new one by clicking on the map."),
                initialPoint: initialPoint,
                existingWaypoints: existingWaypoints
            )
        )
    }

    private func beginGPXRouteImport() {
        activeFileImportKind = .gpx
        isFileImporterPresented = true
    }

    private func beginLibraryImport() {
        activeFileImportKind = .library
        isFileImporterPresented = true
    }

    private func beginLibraryExport() {
        guard let data = viewModel.exportLibraryData() else { return }
        libraryExportDocument = LocationLibraryTransferDocument(data: data)
        showLibraryExporter = true
    }

    private func openCoordinatePickerWindow(_ context: MapPickerContext) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .mapEditor,
            ownerWindowIdentifier: locationSimulationWindowIdentifier,
            title: context.title,
            parentWindow: owningWindow
        ) { close in
            CoordinatePickerSheet(
                title: context.title,
                subtitle: context.subtitle,
                mode: context.mode,
                initialPoint: context.initialPoint,
                existingWaypoints: context.existingWaypoints,
                onClose: close
            ) { output in
                switch output {
                case .point(let selectedPoint):
                    let point = GeoPoint(lat: selectedPoint.latitude, lon: selectedPoint.longitude)
                    switch context.mode {
                    case .addLocation:
                        _ = viewModel.addLocation(at: point)
                        syncSelectionFromViewModel()
                    case .editLocation(let locationID):
                        guard var location = viewModel.locations.first(where: { $0.id == locationID }) else { return }
                        location.point.lat = point.lat
                        location.point.lon = point.lon
                        locationDraft = location
                        viewModel.replaceLocation(location)
                    case .editWaypoints:
                        break
                    }
                case .waypoints(let updatedWaypoints):
                    updateRouteDraft { draft in
                        draft.waypoints = updatedWaypoints
                    }
                }
            }
        }
    }

    private func openLibraryImportSelectionWindow(library: LocationLibrary) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .importSelection,
            ownerWindowIdentifier: locationSimulationWindowIdentifier,
            title: L10n.t("Import Selection"),
            parentWindow: owningWindow
        ) { close in
            LibraryImportSelectionView(library: library, onClose: close) { selectedLocationIDs, selectedRouteIDs in
                viewModel.importSelection(locationIDs: selectedLocationIDs, routeIDs: selectedRouteIDs, from: library)
                syncSelectionFromViewModel()
            }
        }
    }

    private func openGPXPreviewWindow(preview: GPXImportPreview) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .gpxPreview,
            ownerWindowIdentifier: locationSimulationWindowIdentifier,
            title: L10n.t("Import GPX"),
            parentWindow: owningWindow
        ) { close in
            GPXImportPreviewWindowView(preview: preview, onClose: close) { selectedTimeRange, selectedPointRange in
                _ = viewModel.importRoute(
                    from: preview,
                    selectedTimeRange: selectedTimeRange,
                    selectedPointRange: selectedPointRange
                )
                syncSelectionFromViewModel()
            }
        }
    }

    private func selectLocationForLibraryAction(_ locationID: UUID) {
        viewModel.selectLocation(locationID)
        syncSelectionFromViewModel()
    }

    private func selectRouteForLibraryAction(_ routeID: UUID) {
        viewModel.selectRoute(routeID)
        syncSelectionFromViewModel()
    }

    @ViewBuilder
    private func locationContextMenu(for location: SavedLocation) -> some View {
        Button(L10n.t("Set Default"), systemImage: "star") {
            selectLocationForLibraryAction(location.id)
            viewModel.setDefaultLocationToSelection()
        }
        Divider()
        Button(L10n.t("Delete"), systemImage: "trash", role: .destructive) {
            selectLocationForLibraryAction(location.id)
            viewModel.deleteSelectedLocation()
            syncSelectionFromViewModel()
        }
    }

    @ViewBuilder
    private func routeContextMenu(for route: SavedRoute) -> some View {
        Button(L10n.t("Delete"), systemImage: "trash", role: .destructive) {
            selectRouteForLibraryAction(route.id)
            viewModel.deleteSelectedRoute()
            syncSelectionFromViewModel()
        }
    }

    private var libraryExportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "location-library-\(formatter.string(from: Date()))"
    }
}

private struct LocationPreviewMap: NSViewRepresentable {
    let locationID: UUID
    let point: GeoPoint
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsZoomControls = true
        mapView.preferredConfiguration = MKHybridMapConfiguration()
        updateMapView(mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        updateMapView(mapView, coordinator: context.coordinator)
    }

    private func updateMapView(_ mapView: MKMapView, coordinator: Coordinator) {
        let previewKey = "\(locationID.uuidString)|\(point.lat)|\(point.lon)|\(title)"
        if coordinator.lastPreviewKey != previewKey {
            mapView.removeAnnotations(mapView.annotations)

            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            annotation.title = title
            mapView.addAnnotation(annotation)

            let region = MKCoordinateRegion(
                center: annotation.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
            mapView.setRegion(region, animated: false)
            coordinator.lastPreviewKey = previewKey
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastPreviewKey: String?
    }
}

private struct MapPickerContext: Identifiable {
    enum Mode {
        case addLocation
        case editLocation(locationID: UUID)
        case editWaypoints
    }

    let id = UUID()
    let mode: Mode
    let title: String
    let subtitle: String
    let initialPoint: GeoPoint
    let existingWaypoints: [GeoPoint]
}

private enum CoordinatePickerOutput {
    case point(CLLocationCoordinate2D)
    case waypoints([GeoPoint])
}

private struct CoordinatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String
    let mode: MapPickerContext.Mode
    let initialPoint: GeoPoint
    let existingWaypoints: [GeoPoint]
    let onClose: (() -> Void)?
    let onConfirm: (CoordinatePickerOutput) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var editableWaypoints: [GeoPoint]
    @State private var movingWaypointID: UUID?
    @State private var isAddModeEnabled: Bool
    @State private var searchQuery: String
    @State private var searchStatusMessage: String?
    @State private var isSearching: Bool

    private let minVisibleWaypointBadges = 100
    private let maxDraggableWaypointBadges = 140
    private let detailZoomThresholdDelta = 0.008
    private let fullDetailZoomDelta = 0.0009

    init(
        title: String,
        subtitle: String,
        mode: MapPickerContext.Mode,
        initialPoint: GeoPoint,
        existingWaypoints: [GeoPoint],
        onClose: (() -> Void)? = nil,
        onConfirm: @escaping (CoordinatePickerOutput) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.initialPoint = initialPoint
        self.existingWaypoints = existingWaypoints
        self.onClose = onClose
        self.onConfirm = onConfirm

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: initialPoint.lat, longitude: initialPoint.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        _cameraPosition = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
        _editableWaypoints = State(initialValue: existingWaypoints)
        _isAddModeEnabled = State(initialValue: true)
        _searchQuery = State(initialValue: "")
        _searchStatusMessage = State(initialValue: nil)
        _isSearching = State(initialValue: false)

        switch mode {
        case .addLocation, .editLocation:
            _selectedCoordinate = State(
                initialValue: CLLocationCoordinate2D(latitude: initialPoint.lat, longitude: initialPoint.lon)
            )
        case .editWaypoints:
            _selectedCoordinate = State(initialValue: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let searchStatusMessage {
                        Text(searchStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    MapReader { proxy in
                        Map(position: $cameraPosition) {
                            if displayedWaypoints.count > 1 {
                                MapPolyline(coordinates: displayedWaypointsCoordinates)
                                    .stroke(.blue, lineWidth: 2)
                            }

                            ForEach(waypointBadgeItems) { item in
                                let waypoint = item.waypoint
                                Annotation("", coordinate: CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)) {
                                    let badge = waypointBadge(index: item.index + 1, isSelected: waypoint.id == movingWaypointID)
                                        .onTapGesture {
                                            guard usesWaypointEditor else { return }
                                            movingWaypointID = waypoint.id
                                            isAddModeEnabled = false
                                        }
                                    if canDragWaypointBadges {
                                        badge.highPriorityGesture(
                                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                                .onChanged { value in
                                                    guard usesWaypointEditor else { return }
                                                    movingWaypointID = waypoint.id
                                                    isAddModeEnabled = false
                                                    guard let coordinate = proxy.convert(value.location, from: .global) else { return }
                                                    moveWaypoint(withID: waypoint.id, to: coordinate)
                                                }
                                        )
                                    } else {
                                        badge
                                    }
                                }
                            }

                            if usesPointPicker, let selectedCoordinate {
                                Marker(L10n.t("New"), coordinate: selectedCoordinate)
                                    .tint(.red)
                            }
                        }
                        .mapStyle(.hybrid(elevation: .realistic))
                        .onMapCameraChange(frequency: .onEnd) { context in
                            visibleRegion = context.region
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onEnded { value in
                                    let deltaX = value.location.x - value.startLocation.x
                                    let deltaY = value.location.y - value.startLocation.y
                                    let movedDistance = sqrt((deltaX * deltaX) + (deltaY * deltaY))
                                    guard movedDistance < 4 else { return }

                                    if let coordinate = proxy.convert(value.location, from: .local) {
                                        handleMapTap(coordinate)
                                    }
                                }
                        )
                        .overlay(alignment: .topTrailing) {
                            mapZoomControls
                        }
                    }
                    .frame(minHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if usesWaypointEditor {
                        waypointEditorControls
                    }

                    Text(selectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let waypointSamplingStatusText {
                        Text(waypointSamplingStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.t("Cancel")) {
                    close()
                }
                if usesPointPicker {
                    Button(L10n.t("Use Point")) {
                        guard let selectedCoordinate else { return }
                        onConfirm(.point(selectedCoordinate))
                        close()
                    }
                    .disabled(selectedCoordinate == nil)
                } else {
                    Button(L10n.t("Use Waypoints")) {
                        onConfirm(.waypoints(editableWaypoints))
                        close()
                    }
                    .disabled(editableWaypoints.count < 2)
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 560)
        .searchable(
            text: $searchQuery,
            placement: .toolbar,
            prompt: L10n.t("Search place (e.g. Berlin Central Station)")
        )
        .onSubmit(of: .search) {
            runLocationSearch()
        }
    }

    private var selectionText: String {
        if usesPointPicker {
            guard let selectedCoordinate else {
                return L10n.t("Left click on the map to set a coordinate.")
            }
            return String(
                format: L10n.t("Selected: %.6f, %.6f"),
                locale: Locale.current,
                selectedCoordinate.latitude,
                selectedCoordinate.longitude
            )
        }

        if let movingWaypointID,
           let index = editableWaypoints.firstIndex(where: { $0.id == movingWaypointID }) {
            return L10n.f("Move mode: waypoint %d. Left click on the map to move it.", index + 1)
        }

        if !isAddModeEnabled {
            return L10n.t("No mode active. Enable Add Mode or select a waypoint to move.")
        }

        return L10n.t("Add mode: Left click on the map to add a new waypoint.")
    }

    private var displayedWaypoints: [GeoPoint] {
        usesWaypointEditor ? editableWaypoints : existingWaypoints
    }

    private var displayedWaypointsCoordinates: [CLLocationCoordinate2D] {
        displayedWaypoints.map { waypoint in
            CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)
        }
    }

    private var canDragWaypointBadges: Bool {
        usesWaypointEditor && waypointBadgeItems.count <= maxDraggableWaypointBadges
    }

    private var visibleWaypointBadgeLimit: Int {
        let total = displayedWaypoints.count
        guard usesWaypointEditor else { return total }
        guard total > minVisibleWaypointBadges else { return total }

        let currentDelta = max(visibleRegion.span.latitudeDelta, visibleRegion.span.longitudeDelta)

        if currentDelta >= detailZoomThresholdDelta {
            return minVisibleWaypointBadges
        }

        if currentDelta <= fullDetailZoomDelta {
            return total
        }

        let zoomProgress = (detailZoomThresholdDelta - currentDelta) / (detailZoomThresholdDelta - fullDetailZoomDelta)
        let clampedProgress = min(max(zoomProgress, 0), 1)
        let easedProgress = pow(clampedProgress, 2.6)
        let scaledLimit = Double(minVisibleWaypointBadges)
            + easedProgress * Double(total - minVisibleWaypointBadges)

        return min(total, max(minVisibleWaypointBadges, Int(round(scaledLimit))))
    }

    private var waypointBadgeItems: [WaypointBadgeItem] {
        let source = displayedWaypoints.enumerated().map { offset, waypoint in
            WaypointBadgeItem(index: offset, waypoint: waypoint)
        }

        let badgeLimit = visibleWaypointBadgeLimit
        guard usesWaypointEditor, source.count > badgeLimit else {
            return source
        }

        var fixedWaypointIDs = Set<UUID>()
        if let firstID = source.first?.waypoint.id {
            fixedWaypointIDs.insert(firstID)
        }
        if let lastID = source.last?.waypoint.id {
            fixedWaypointIDs.insert(lastID)
        }
        if let movingWaypointID {
            fixedWaypointIDs.insert(movingWaypointID)
        }

        var selectedItems: [WaypointBadgeItem] = []
        var selectedWaypointIDs = Set<UUID>()

        for item in source where fixedWaypointIDs.contains(item.waypoint.id) {
            if selectedWaypointIDs.insert(item.waypoint.id).inserted {
                selectedItems.append(item)
            }
        }

        let samplingBudget = max(badgeLimit - selectedItems.count, 0)
        guard samplingBudget > 0 else {
            return selectedItems.sorted { $0.index < $1.index }
        }

        let samplingStride = max(1, Int(ceil(Double(source.count) / Double(samplingBudget))))
        for sourceIndex in stride(from: 0, to: source.count, by: samplingStride) {
            let item = source[sourceIndex]
            if selectedWaypointIDs.insert(item.waypoint.id).inserted {
                selectedItems.append(item)
            }
            if selectedItems.count >= badgeLimit {
                break
            }
        }

        return selectedItems.sorted { $0.index < $1.index }
    }

    private var waypointSamplingStatusText: String? {
        let total = displayedWaypoints.count
        let limit = visibleWaypointBadgeLimit
        guard usesWaypointEditor, total > limit else {
            return nil
        }
        return L10n.f(
            "Performance mode: showing %d of %d markers (zoom limit %d).",
            waypointBadgeItems.count,
            total,
            limit
        )
    }

    private var usesPointPicker: Bool {
        switch mode {
        case .addLocation, .editLocation:
            return true
        case .editWaypoints:
            return false
        }
    }

    private var usesWaypointEditor: Bool {
        !usesPointPicker
    }

    private var mapZoomControls: some View {
        VStack(spacing: 8) {
            Button {
                zoomMap(by: 0.5)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .help(L10n.t("Zoom in"))

            Button {
                zoomMap(by: 2.0)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help(L10n.t("Zoom out"))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    @ViewBuilder
    private var waypointEditorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("Waypoints"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if isAddModeEnabled {
                    Button(L10n.t("Add Mode")) {
                        isAddModeEnabled = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(L10n.t("Add Mode")) {
                        isAddModeEnabled = true
                        movingWaypointID = nil
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(editableWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                        HStack {
                            Text("#\(index + 1)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(width: 28, alignment: .leading)

                            Text(
                                String(
                                    format: "%.6f, %.6f",
                                    locale: Locale.current,
                                    waypoint.lat,
                                    waypoint.lon
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                            Spacer()

                            Button(movingWaypointID == waypoint.id ? L10n.t("Moving...") : L10n.t("Move")) {
                                movingWaypointID = waypoint.id
                                isAddModeEnabled = false
                            }
                            .disabled(movingWaypointID == waypoint.id)

                            Button(role: .destructive) {
                                editableWaypoints.removeAll { $0.id == waypoint.id }
                                if movingWaypointID == waypoint.id {
                                    movingWaypointID = nil
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: waypointListHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        if usesPointPicker {
            selectedCoordinate = coordinate
            return
        }

        if let movingWaypointID,
           let index = editableWaypoints.firstIndex(where: { $0.id == movingWaypointID }) {
            editableWaypoints[index].lat = coordinate.latitude
            editableWaypoints[index].lon = coordinate.longitude
            return
        }

        guard isAddModeEnabled else { return }
        editableWaypoints.append(GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude))
    }

    private func moveWaypoint(withID id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard let index = editableWaypoints.firstIndex(where: { $0.id == id }) else { return }
        editableWaypoints[index].lat = coordinate.latitude
        editableWaypoints[index].lon = coordinate.longitude
    }

    private func zoomMap(by factor: Double) {
        let minDelta = 0.0005
        let maxDelta = 120.0

        var region = visibleRegion
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, minDelta), maxDelta)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, minDelta), maxDelta)
        visibleRegion = region
        cameraPosition = .region(region)
    }

    private func runLocationSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        searchStatusMessage = nil

        Task {
            await performLocationSearch(query: trimmed)
        }
    }

    @MainActor
    private func performLocationSearch(query: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = visibleRegion
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let first = response.mapItems.first else {
                searchStatusMessage = L10n.f("No results found for \"%@\".", query)
                isSearching = false
                return
            }

            let coordinate = first.location.coordinate
            centerMap(on: coordinate)
            searchStatusMessage = first.name
                ?? first.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? L10n.t("Result found")
        } catch {
            searchStatusMessage = L10n.f("Search failed: %@", error.localizedDescription)
        }

        isSearching = false
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        let latDelta = min(max(visibleRegion.span.latitudeDelta, 0.005), 0.2)
        let lonDelta = min(max(visibleRegion.span.longitudeDelta, 0.005), 0.2)
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        visibleRegion = region
        cameraPosition = .region(region)
    }

    private var waypointListHeight: CGFloat {
        let rowHeight: CGFloat = 32
        let rowCount = max(1, min(editableWaypoints.count, 5))
        return (CGFloat(rowCount) * rowHeight) + 10
    }

    @ViewBuilder
    private func waypointBadge(index: Int, isSelected: Bool) -> some View {
        Text("\(index)")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(isSelected ? Color.orange : Color.blue)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            )
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private struct WaypointBadgeItem: Identifiable {
        let index: Int
        let waypoint: GeoPoint

        var id: UUID { waypoint.id }
    }
}
