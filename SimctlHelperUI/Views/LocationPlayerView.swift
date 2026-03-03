import SwiftUI
import UniformTypeIdentifiers
import MapKit
import AppKit

struct LocationPlayerView: View {
    private enum FileImportKind {
        case gpx
        case library
    }

    private enum PlayerMode: String, CaseIterable, Identifiable {
        case singleLocation = "Single Location"
        case route = "Route"

        var id: Self { self }
    }

    @StateObject var viewModel: LocationPlayerViewModel
    @State private var activeFileImportKind: FileImportKind?
    @State private var isFileImporterPresented = false
    @State private var showLibraryExporter = false
    @State private var mapPickerContext: MapPickerContext?
    @State private var selectedLocationID: UUID?
    @State private var selectedRouteID: UUID?
    @State private var locationDraft: SavedLocation?
    @State private var routeDraft: SavedRoute?
    @State private var isSyncingSelection = false
    @State private var gpxImportContext: GPXImportContext?
    @State private var libraryExportDocument = LocationLibraryDocument(data: Data())
    @State private var importSelectionContext: ImportSelectionContext?
    @State private var renameContext: RenameContext?
    @State private var playerMode: PlayerMode = .singleLocation
    @State private var pendingLocationSaveTask: Task<Void, Never>?
    @State private var pendingRouteSaveTask: Task<Void, Never>?
    @State private var isDebugLogExpanded = false

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

    private let inlineWaypointEditingLimit = 20
    private let mapWaypointEditingLimit = 1_500

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            HSplitView {
                libraryPanel
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

                detailPanel
                    .frame(minWidth: 500, maxWidth: .infinity)
            }
            .layoutPriority(1)

            Divider()
            playbackControls
        }
        .navigationTitle("Location Player - \(viewModel.deviceName)")
        .onAppear {
            viewModel.start()
            ensureSelectionForCurrentMode()
            syncSelectionFromViewModel()
        }
        .onDisappear {
            viewModel.handleWindowClose()
        }
        .onChange(of: selectedLocationID) { _, value in
            guard !isSyncingSelection else { return }

            if value == nil,
               playerMode == .singleLocation,
               !viewModel.locations.isEmpty,
               let existing = viewModel.selectedLocationID {
                // Ignore transient list deselection while rows are being refreshed.
                isSyncingSelection = true
                selectedLocationID = existing
                isSyncingSelection = false
                return
            }

            viewModel.selectLocation(value)
            syncLocationDraft()
        }
        .onChange(of: selectedRouteID) { _, value in
            guard !isSyncingSelection else { return }

            if value == nil,
               playerMode == .route,
               !viewModel.routes.isEmpty,
               let existing = viewModel.selectedRouteID {
                // Ignore transient list deselection while rows are being refreshed.
                isSyncingSelection = true
                selectedRouteID = existing
                isSyncingSelection = false
                return
            }

            viewModel.selectRoute(value)
            syncRouteDraft()
        }
        .onChange(of: viewModel.selectedLocationID) { _, value in
            guard value != selectedLocationID else { return }
            syncSelectionFromViewModel()
        }
        .onChange(of: viewModel.selectedRouteID) { _, value in
            guard value != selectedRouteID else { return }
            syncSelectionFromViewModel()
        }
        .onChange(of: viewModel.locations) { _, _ in
            syncLocationDraft()
        }
        .onChange(of: viewModel.routes) { _, _ in
            syncRouteDraft()
        }
        .onChange(of: playerMode) { _, _ in
            ensureSelectionForCurrentMode()
            syncSelectionFromViewModel()
        }
        .sheet(item: $mapPickerContext) { context in
            CoordinatePickerSheet(
                title: context.title,
                subtitle: context.subtitle,
                mode: context.mode,
                initialPoint: context.initialPoint,
                existingWaypoints: context.existingWaypoints
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
        .sheet(item: $importSelectionContext) { context in
            LibraryImportSelectionSheet(library: context.library) { selectedLocationIDs, selectedRouteIDs in
                viewModel.importSelection(
                    locationIDs: selectedLocationIDs,
                    routeIDs: selectedRouteIDs,
                    from: context.library
                )
                syncSelectionFromViewModel()
            }
        }
        .sheet(item: $gpxImportContext) { context in
            GPXImportPreviewSheet(preview: context.preview) { selectedTimeRange, selectedPointRange in
                viewModel.importRoute(
                    from: context.preview,
                    selectedTimeRange: selectedTimeRange,
                    selectedPointRange: selectedPointRange
                )
                syncSelectionFromViewModel()
            }
        }
        .sheet(item: $renameContext) { context in
            RenameItemSheet(
                title: context.title,
                initialName: context.currentName
            ) { newName in
                switch context.item {
                case .location(let locationID):
                    viewModel.renameLocation(id: locationID, to: newName)
                case .route(let routeID):
                    viewModel.renameRoute(id: routeID, to: newName)
                }
                syncSelectionFromViewModel()
            }
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
                    gpxImportContext = GPXImportContext(preview: preview)
                case .library:
                    guard let importedLibrary = viewModel.importLibrary(from: fileURL) else { return }
                    importSelectionContext = ImportSelectionContext(library: importedLibrary)
                case .none:
                    break
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showLibraryExporter,
            document: libraryExportDocument,
            contentType: .json,
            defaultFilename: libraryExportFilename
        ) { result in
            if case .failure(let error) = result {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Target Device")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker(
                    "Target Device",
                    selection: Binding(
                        get: { viewModel.udid },
                        set: { viewModel.selectTargetDevice($0) }
                    )
                ) {
                    if viewModel.availableDevices.isEmpty {
                        Text("No devices found").tag("")
                    } else {
                        ForEach(viewModel.availableDevices) { device in
                            Text("\(device.name) (\(device.isBooted ? "Booted" : "Shutdown"))")
                                .tag(device.udid)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 300)
                .disabled(viewModel.availableDevices.isEmpty)

                Toggle("Auto-Boot on Send", isOn: $viewModel.autoBootOnSend)
                    .toggleStyle(.checkbox)

                Spacer()
            }

            HStack(spacing: 12) {
                Text("Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("Mode", selection: $playerMode) {
                    ForEach(PlayerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Spacer()
            }

            HStack(spacing: 12) {
                Text("UDID: \(viewModel.udid)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isDeviceBooted ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isDeviceBooted ? "Booted" : "Shutdown")
                        .font(.caption)
                        .foregroundColor(viewModel.isDeviceBooted ? .primary : .secondary)
                }

                Text("Default: \(viewModel.defaultLocationName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch playerMode {
            case .singleLocation:
                GroupBox("Locations") {
                    VStack(spacing: 8) {
                        List(selection: $selectedLocationID) {
                            ForEach(viewModel.locations) { location in
                                HStack {
                                    Text(location.name)
                                    Spacer()
                                    if viewModel.defaultLocationID == location.id {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(.yellow)
                                    }
                                }
                                .tag(location.id)
                            }
                        }
                        .frame(minHeight: 180)

                        HStack {
                            Button("Add") {
                                openLocationMapPicker()
                            }
                            Button("Rename") {
                                beginRenameSelectedLocation()
                            }
                            .disabled(viewModel.selectedLocationID == nil)
                            Button("Delete") {
                                viewModel.deleteSelectedLocation()
                                syncSelectionFromViewModel()
                            }
                            .disabled(viewModel.selectedLocationID == nil)
                            Button("Set Default") {
                                viewModel.setDefaultLocationToSelection()
                            }
                            .disabled(viewModel.selectedLocationID == nil)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .route:
                GroupBox("Routes") {
                    VStack(spacing: 8) {
                        List(selection: $selectedRouteID) {
                            ForEach(viewModel.routes) { route in
                                Text(route.name)
                                    .tag(route.id)
                            }
                        }
                        .frame(minHeight: 180)

                        HStack {
                            Button("Add") {
                                viewModel.addRoute()
                                syncSelectionFromViewModel()
                            }
                            Button("Rename") {
                                beginRenameSelectedRoute()
                            }
                            .disabled(viewModel.selectedRouteID == nil)
                            Button("Delete") {
                                viewModel.deleteSelectedRoute()
                                syncSelectionFromViewModel()
                            }
                            .disabled(viewModel.selectedRouteID == nil)
                            Button("Import GPX") {
                                activeFileImportKind = .gpx
                                isFileImporterPresented = true
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            GroupBox("Library File") {
                HStack {
                    Button("Export All") {
                        beginLibraryExport()
                    }
                    Button("Import...") {
                        activeFileImportKind = .library
                        isFileImporterPresented = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch playerMode {
                case .singleLocation:
                    if let locationDraft {
                        locationDetails(location: locationDraft)
                    } else {
                        Text("Select a location from the library.")
                            .foregroundColor(.secondary)
                    }
                case .route:
                    if let routeDraft {
                        routeDetails(route: routeDraft)
                    } else {
                        Text("Select a route from the library.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    private func locationDetails(location: SavedLocation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location Details")
                .font(.headline)

            TextField("Name", text: Binding(
                get: { locationDraft?.name ?? "" },
                set: { value in
                    updateLocationDraft { $0.name = value }
                }
            ))

            HStack(spacing: 12) {
                TextField("Latitude", value: Binding(
                    get: { locationDraft?.point.lat ?? location.point.lat },
                    set: { value in
                        updateLocationDraft { $0.point.lat = value }
                    }
                ), format: .number.precision(.fractionLength(1...8)))

                TextField("Longitude", value: Binding(
                    get: { locationDraft?.point.lon ?? location.point.lon },
                    set: { value in
                        updateLocationDraft { $0.point.lon = value }
                    }
                ), format: .number.precision(.fractionLength(1...8)))
            }

            Button("Edit On Map") {
                openLocationEditMapPicker(location)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func routeDetails(route: SavedRoute) -> some View {
        let waypoints = routeDraft?.waypoints ?? route.waypoints
        let directlyVisibleWaypoints = Array(waypoints.prefix(inlineWaypointEditingLimit))
        let hiddenWaypointCount = max(0, waypoints.count - directlyVisibleWaypoints.count)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Route Details")
                .font(.headline)

            HStack {
                Text("Name")
                    .frame(width: 120, alignment: .leading)
                TextField("Route Name", text: Binding(
                    get: { routeDraft?.name ?? route.name },
                    set: { value in
                        updateRouteDraft { $0.name = value }
                    }
                ))
            }

            HStack {
                Text("Speed (m/s)")
                    .frame(width: 120, alignment: .leading)
                TextField("20.0", value: Binding(
                    get: { routeDraft?.speedMetersPerSecond ?? route.speedMetersPerSecond },
                    set: { value in
                        updateRouteDraft { $0.speedMetersPerSecond = value }
                    }
                ), format: .number.precision(.fractionLength(1...4)))
            }

            Picker("Update Mode", selection: Binding(
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
                        switch selection {
                        case 0:
                            route.updateMode = .interval(seconds: 1)
                        default:
                            route.updateMode = .distance(meters: 10)
                        }
                    }
                }
            )) {
                Text("Interval").tag(0)
                Text("Distance").tag(1)
            }
            .pickerStyle(.segmented)

            Group {
                if case .interval(let seconds) = routeDraft?.updateMode ?? route.updateMode {
                    HStack {
                        Text("Interval (s)")
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
                        Text("Distance (m)")
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
                    Text("Waypoints (\(waypoints.count))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Edit On Map") {
                        openWaypointMapPicker()
                    }
                }

                if hiddenWaypointCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Direct edit is limited to the first \(inlineWaypointEditingLimit) waypoints.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let first = waypoints.first, let last = waypoints.last {
                            Text(
                                String(
                                    format: "Start: %.6f, %.6f  |  End: %.6f, %.6f",
                                    locale: Locale(identifier: "en_US_POSIX"),
                                    first.lat, first.lon, last.lat, last.lon
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        }
                        Text("+ \(hiddenWaypointCount) additional waypoints hidden in direct editor.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(directlyVisibleWaypoints) { waypoint in
                    HStack(spacing: 8) {
                        TextField("Lat", value: Binding(
                            get: { waypointLatitude(for: waypoint.id) ?? waypoint.lat },
                            set: { value in
                                updateRouteDraft { draft in
                                    guard let index = draft.waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
                                    draft.waypoints[index].lat = value
                                }
                            }
                        ), format: .number.precision(.fractionLength(1...8)))

                        TextField("Lon", value: Binding(
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
        .cornerRadius(8)
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.hasTargetDevice {
                Text("No target simulator selected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !viewModel.isDeviceBooted, viewModel.autoBootOnSend {
                Text("Selected simulator is shutdown. Actions will boot it automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !viewModel.isDeviceBooted {
                Text("Selected simulator is shutdown.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if playerMode == .singleLocation {
                HStack {
                    Button("Set Location") {
                        flushLocationDraftSave()
                        viewModel.applySelectedLocation()
                    }
                    .disabled(!viewModel.hasTargetDevice || viewModel.selectedLocationID == nil)

                    Button("Clear Location") {
                        viewModel.clearAppliedLocation()
                    }
                    .disabled(!viewModel.hasTargetDevice)

                    Button("Reset To Default Location") {
                        flushLocationDraftSave()
                        viewModel.resetToDefaultLocation()
                    }
                    .disabled(!viewModel.hasTargetDevice || viewModel.defaultLocationID == nil)

                    Spacer()

                    Text("Single location mode")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Button("Play") {
                        flushRouteDraftSave()
                        viewModel.playSelectedRoute()
                    }
                    .disabled(isPlayDisabled)

                    Button(pauseButtonTitle) {
                        viewModel.togglePauseResume()
                    }
                    .disabled(isPauseDisabled)

                    Button("Stop") {
                        viewModel.stop()
                    }
                    .disabled(isStopDisabled)

                    Spacer()

                    Text(routeStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                DisclosureGroup(isExpanded: $isDebugLogExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Copy Log") {
                                copyDebugLogToClipboard()
                            }
                            .disabled(viewModel.debugLogText.isEmpty)

                            Button("Clear Log") {
                                viewModel.clearDebugLog()
                            }

                            Button("Refresh") {
                                viewModel.refreshDebugLog()
                            }

                            Spacer()
                        }

                        ScrollView {
                            Text(viewModel.debugLogText.isEmpty ? "No debug entries yet." : viewModel.debugLogText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 90, maxHeight: 130)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .cornerRadius(6)
                    }
                } label: {
                    HStack {
                        Text("Debug Log")
                        Spacer()
                        Text("\(viewModel.debugLogLineCount) lines")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var canPauseResume: Bool {
        guard playerMode == .route else {
            return false
        }
        switch viewModel.playbackState {
        case .running, .paused:
            return true
        default:
            return false
        }
    }

    private var pauseButtonTitle: String {
        guard playerMode == .route else {
            return "Pause"
        }
        switch viewModel.playbackState {
        case .running:
            return "Pause"
        case .paused:
            return "Resume"
        default:
            return "Pause/Resume"
        }
    }

    private var routeStatusText: String {
        switch viewModel.playbackState {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .finished:
            return "Finished"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var isPlayDisabled: Bool {
        !viewModel.hasTargetDevice || viewModel.selectedRouteID == nil
    }

    private var isPauseDisabled: Bool {
        !viewModel.hasTargetDevice || !canPauseResume
    }

    private var isStopDisabled: Bool {
        !viewModel.hasTargetDevice || !viewModel.canStopRoute
    }

    private func ensureSelectionForCurrentMode() {
        switch playerMode {
        case .singleLocation:
            if viewModel.selectedLocationID == nil {
                viewModel.selectLocation(viewModel.locations.first?.id)
            }
        case .route:
            if viewModel.selectedRouteID == nil {
                viewModel.selectRoute(viewModel.routes.first?.id)
            }
        }
    }

    private func syncSelectionFromViewModel() {
        isSyncingSelection = true
        selectedLocationID = viewModel.selectedLocationID
        selectedRouteID = viewModel.selectedRouteID
        isSyncingSelection = false
        syncLocationDraft()
        syncRouteDraft()
    }

    private func syncLocationDraft() {
        guard let selectedLocationID,
              let location = viewModel.locations.first(where: { $0.id == selectedLocationID }) else {
            locationDraft = nil
            return
        }
        locationDraft = location
    }

    private func syncRouteDraft() {
        guard let selectedRouteID,
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

        mapPickerContext = MapPickerContext(
            mode: .addLocation,
            title: "Choose Location Point",
            subtitle: "Click on the map to place the new saved location.",
            initialPoint: initialPoint,
            existingWaypoints: []
        )
    }

    private func openLocationEditMapPicker(_ location: SavedLocation) {
        mapPickerContext = MapPickerContext(
            mode: .editLocation(locationID: location.id),
            title: "Edit Location Point",
            subtitle: "Click on the map to move this location.",
            initialPoint: location.point,
            existingWaypoints: []
        )
    }

    private func openWaypointMapPicker() {
        let existingWaypoints = routeDraft?.waypoints ?? []
        guard existingWaypoints.count <= mapWaypointEditingLimit else {
            viewModel.errorMessage = "Map waypoint editor supports up to \(mapWaypointEditingLimit) waypoints. Reduce route size first."
            return
        }
        let initialPoint = existingWaypoints.last
            ?? locationDraft?.point
            ?? viewModel.locations.first?.point
            ?? GeoPoint(lat: 37.3349, lon: -122.0090)

        mapPickerContext = MapPickerContext(
            mode: .editWaypoints,
            title: "Edit Waypoints",
            subtitle: "Select a waypoint to move, or add a new one by clicking on the map.",
            initialPoint: initialPoint,
            existingWaypoints: existingWaypoints
        )
    }

    private func copyDebugLogToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.debugLogShareText, forType: .string)
    }

    private func beginLibraryExport() {
        guard let data = viewModel.exportLibraryData() else { return }
        libraryExportDocument = LocationLibraryDocument(data: data)
        showLibraryExporter = true
    }

    private func beginRenameSelectedLocation() {
        flushLocationDraftSave()
        guard let selectedLocationID = viewModel.selectedLocationID,
              let location = viewModel.locations.first(where: { $0.id == selectedLocationID }) else {
            return
        }
        renameContext = RenameContext(item: .location(location.id), currentName: location.name)
    }

    private func beginRenameSelectedRoute() {
        flushRouteDraftSave()
        guard let selectedRouteID = viewModel.selectedRouteID,
              let route = viewModel.routes.first(where: { $0.id == selectedRouteID }) else {
            return
        }
        renameContext = RenameContext(item: .route(route.id), currentName: route.name)
    }

    private var libraryExportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "location-library-\(formatter.string(from: Date()))"
    }
}

private struct GPXImportContext: Identifiable {
    let id = UUID()
    let preview: GPXImportPreview
}

private struct RenameContext: Identifiable {
    enum Item {
        case location(UUID)
        case route(UUID)
    }

    let id = UUID()
    let item: Item
    let currentName: String

    var title: String {
        switch item {
        case .location:
            return "Rename Location"
        case .route:
            return "Rename Route"
        }
    }
}

private struct RenameItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialName: String
    let onConfirm: (String) -> Void

    @State private var name: String

    init(title: String, initialName: String, onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onConfirm(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

private struct GPXImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preview: GPXImportPreview
    let onImport: (ClosedRange<Date>?, ClosedRange<Int>?) -> Void

    @State private var selectedStartFraction: Double
    @State private var selectedEndFraction: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion

    init(preview: GPXImportPreview, onImport: @escaping (ClosedRange<Date>?, ClosedRange<Int>?) -> Void) {
        self.preview = preview
        self.onImport = onImport

        let defaultRegion = GPXImportPreviewSheet.mapRegion(for: preview.points.map(\.point))
        _cameraPosition = State(initialValue: .region(defaultRegion))
        _visibleRegion = State(initialValue: defaultRegion)
        _selectedStartFraction = State(initialValue: 0)
        _selectedEndFraction = State(initialValue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import GPX")
                .font(.headline)
            Text(preview.name)
                .font(.title3)
            Text(summaryText)
                .font(.caption)
                .foregroundColor(.secondary)

            Map(position: $cameraPosition, interactionModes: [.zoom, .pan]) {
                if allCoordinates.count > 1 {
                    MapPolyline(coordinates: allCoordinates)
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 2)
                }

                if selectedCoordinates.count > 1 {
                    MapPolyline(coordinates: selectedCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }

                if let first = selectedCoordinates.first {
                    Marker("Start", coordinate: first)
                        .tint(.green)
                }

                if let last = selectedCoordinates.last {
                    Marker("Ende", coordinate: last)
                        .tint(.red)
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
            }
            .overlay(alignment: .topTrailing) {
                mapZoomControls
            }
            .frame(minHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(preview.canSelectTimeRange ? "Zeitbereich" : "Wegpunktbereich")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                GPXTimelineRangeSelector(
                    startFraction: $selectedStartFraction,
                    endFraction: $selectedEndFraction
                )
                .frame(height: 36)

                HStack {
                    Text(selectedRangeStartText)
                    Spacer()
                    Text(selectedRangeEndText)
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            }

            Text(selectionSummaryText)
                .font(.caption)
                .foregroundColor(.secondary)

            if !canImportSelection {
                Text("Im gewaehlten Bereich muessen mindestens zwei Punkte enthalten sein.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Import Selection") {
                    onImport(
                        preview.canSelectTimeRange ? selectedTimeRange : nil,
                        preview.canSelectTimeRange ? nil : selectedPointRange
                    )
                    dismiss()
                }
                .disabled(!canImportSelection)
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 700)
    }

    private var selectedTimeRange: ClosedRange<Date>? {
        guard let fullTimeRange = preview.timeRange else { return nil }
        let duration = fullTimeRange.upperBound.timeIntervalSince(fullTimeRange.lowerBound)
        guard duration > 0 else { return nil }
        let lower = fullTimeRange.lowerBound.addingTimeInterval(duration * selectedStartFraction)
        let upper = fullTimeRange.lowerBound.addingTimeInterval(duration * selectedEndFraction)
        return lower...upper
    }

    private var selectedPointRange: ClosedRange<Int>? {
        guard !preview.points.isEmpty else { return nil }
        let maxIndex = preview.points.count - 1
        let lower = Int(floor(selectedStartFraction * Double(maxIndex)))
        let upper = Int(ceil(selectedEndFraction * Double(maxIndex)))
        let clampedLower = max(0, min(maxIndex, lower))
        let clampedUpper = max(clampedLower, min(maxIndex, upper))
        return clampedLower...clampedUpper
    }

    private var selectedPoints: [GPXTimestampedPoint] {
        if let selectedTimeRange {
            return preview.points(in: selectedTimeRange)
        }
        if let selectedPointRange {
            return preview.points(in: selectedPointRange)
        }
        return preview.points
    }

    private var allCoordinates: [CLLocationCoordinate2D] {
        preview.points.map { point in
            CLLocationCoordinate2D(latitude: point.point.lat, longitude: point.point.lon)
        }
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        selectedPoints.map { point in
            CLLocationCoordinate2D(latitude: point.point.lat, longitude: point.point.lon)
        }
    }

    private var canImportSelection: Bool {
        selectedPoints.count >= 2
    }

    private var summaryText: String {
        if let fullTimeRange = preview.timeRange {
            let duration = fullTimeRange.upperBound.timeIntervalSince(fullTimeRange.lowerBound)
            return "\(preview.totalPointCount) Punkte, Zeitraum: \(formattedDuration(duration))"
        }
        return "\(preview.totalPointCount) Punkte (ohne Zeitstempel)"
    }

    private var selectionSummaryText: String {
        let base = "\(selectedPoints.count) von \(preview.totalPointCount) Punkten im Importbereich"
        if let selectedTimeRange {
            let duration = selectedTimeRange.upperBound.timeIntervalSince(selectedTimeRange.lowerBound)
            return "\(base) (\(formattedDuration(duration)))"
        }
        if let selectedPointRange {
            return "\(base) (WP \(selectedPointRange.lowerBound + 1)-\(selectedPointRange.upperBound + 1))"
        }
        return base
    }

    private var selectedRangeStartText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.lowerBound)
        }
        if let selectedPointRange {
            return "WP \(selectedPointRange.lowerBound + 1)"
        }
        return "WP 1"
    }

    private var selectedRangeEndText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.upperBound)
        }
        if let selectedPointRange {
            return "WP \(selectedPointRange.upperBound + 1)"
        }
        return "WP 1"
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
            .help("Zoom in")

            Button {
                zoomMap(by: 2.0)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Zoom out")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
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

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return Self.dateFormatter.string(from: date)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let resolved = max(0, duration)
        return Self.durationFormatter.string(from: resolved) ?? String(format: "%.0fs", resolved)
    }

    private static func mapRegion(for points: [GeoPoint]) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        }

        let latitudes = points.map(\.lat)
        let longitudes = points.map(\.lon)
        let minLat = latitudes.min() ?? first.lat
        let maxLat = latitudes.max() ?? first.lat
        let minLon = longitudes.min() ?? first.lon
        let maxLon = longitudes.max() ?? first.lon

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latDelta = max((maxLat - minLat) * 1.25, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.25, 0.01)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter
    }()
}

private struct GPXTimelineRangeSelector: View {
    @Binding var startFraction: Double
    @Binding var endFraction: Double

    @State private var startDragOrigin: Double?
    @State private var endDragOrigin: Double?
    @State private var rangeDragOrigin: (Double, Double)?

    private let handleDiameter: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(1, geometry.size.width - handleDiameter)
            let startX = CGFloat(startFraction) * trackWidth + (handleDiameter / 2)
            let endX = CGFloat(endFraction) * trackWidth + (handleDiameter / 2)
            let selectedWidth = max(endX - startX, handleDiameter / 2)
            let selectedMidX = startX + (selectedWidth / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 8)
                    .padding(.horizontal, handleDiameter / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: selectedWidth, height: 8)
                    .position(x: selectedMidX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if rangeDragOrigin == nil {
                                    rangeDragOrigin = (startFraction, endFraction)
                                }

                                guard let origin = rangeDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                let span = origin.1 - origin.0
                                let minStart = 0.0
                                let maxStart = 1.0 - span
                                let clampedStart = min(max(origin.0 + delta, minStart), maxStart)
                                startFraction = clampedStart
                                endFraction = clampedStart + span
                            }
                            .onEnded { _ in
                                rangeDragOrigin = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .position(x: startX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if startDragOrigin == nil {
                                    startDragOrigin = startFraction
                                }

                                guard let origin = startDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                startFraction = min(max(origin + delta, 0), endFraction)
                            }
                            .onEnded { _ in
                                startDragOrigin = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .position(x: endX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if endDragOrigin == nil {
                                    endDragOrigin = endFraction
                                }

                                guard let origin = endDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                endFraction = max(min(origin + delta, 1), startFraction)
                            }
                            .onEnded { _ in
                                endDragOrigin = nil
                            }
                    )
            }
        }
    }
}

private struct ImportSelectionContext: Identifiable {
    let id = UUID()
    let library: LocationLibrary
}

private struct LocationLibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct LibraryImportSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let library: LocationLibrary
    let onImport: (Set<UUID>, Set<UUID>) -> Void

    @State private var selectedLocationIDs: Set<UUID>
    @State private var selectedRouteIDs: Set<UUID>

    init(library: LocationLibrary, onImport: @escaping (Set<UUID>, Set<UUID>) -> Void) {
        self.library = library
        self.onImport = onImport
        _selectedLocationIDs = State(initialValue: Set(library.locations.map(\.id)))
        _selectedRouteIDs = State(initialValue: Set(library.routes.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Selection")
                .font(.headline)
            Text("Waehle aus, welche Locations und Routen importiert werden sollen.")
                .font(.caption)
                .foregroundColor(.secondary)

            GroupBox("Locations (\(selectedLocationIDs.count)/\(library.locations.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("All") {
                            selectedLocationIDs = Set(library.locations.map(\.id))
                        }
                        Button("None") {
                            selectedLocationIDs.removeAll()
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(library.locations) { location in
                                Toggle(
                                    location.name,
                                    isOn: Binding(
                                        get: { selectedLocationIDs.contains(location.id) },
                                        set: { isOn in
                                            if isOn {
                                                selectedLocationIDs.insert(location.id)
                                            } else {
                                                selectedLocationIDs.remove(location.id)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: 140)
                }
            }

            GroupBox("Routes (\(selectedRouteIDs.count)/\(library.routes.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("All") {
                            selectedRouteIDs = Set(library.routes.map(\.id))
                        }
                        Button("None") {
                            selectedRouteIDs.removeAll()
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(library.routes) { route in
                                Toggle(
                                    route.name,
                                    isOn: Binding(
                                        get: { selectedRouteIDs.contains(route.id) },
                                        set: { isOn in
                                            if isOn {
                                                selectedRouteIDs.insert(route.id)
                                            } else {
                                                selectedRouteIDs.remove(route.id)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: 140)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Import Selection") {
                    onImport(selectedLocationIDs, selectedRouteIDs)
                    dismiss()
                }
                .disabled(selectedLocationIDs.isEmpty && selectedRouteIDs.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
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

    init(
        title: String,
        subtitle: String,
        mode: MapPickerContext.Mode,
        initialPoint: GeoPoint,
        existingWaypoints: [GeoPoint],
        onConfirm: @escaping (CoordinatePickerOutput) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.initialPoint = initialPoint
        self.existingWaypoints = existingWaypoints
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
        if case .addLocation = mode {
            _selectedCoordinate = State(
                initialValue: CLLocationCoordinate2D(latitude: initialPoint.lat, longitude: initialPoint.lon)
            )
        } else if case .editLocation = mode {
            _selectedCoordinate = State(
                initialValue: CLLocationCoordinate2D(latitude: initialPoint.lat, longitude: initialPoint.lon)
            )
        } else {
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
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("Ort suchen (z. B. Berlin Hbf)", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                runLocationSearch()
                            }

                        Button("Suchen") {
                            runLocationSearch()
                        }
                        .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    }

                    if let searchStatusMessage {
                        Text(searchStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    MapReader { proxy in
                        Map(position: $cameraPosition) {
                            if displayedWaypoints.count > 1 {
                                MapPolyline(coordinates: displayedWaypointsCoordinates)
                                    .stroke(.blue, lineWidth: 2)
                            }

                            ForEach(Array(displayedWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                                Annotation("", coordinate: CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)) {
                                    waypointBadge(index: index + 1, isSelected: waypoint.id == movingWaypointID)
                                        .onTapGesture {
                                            guard usesWaypointEditor else { return }
                                            movingWaypointID = waypoint.id
                                            isAddModeEnabled = false
                                        }
                                        .highPriorityGesture(
                                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                                .onChanged { value in
                                                    guard usesWaypointEditor else { return }
                                                    movingWaypointID = waypoint.id
                                                    isAddModeEnabled = false
                                                    guard let coordinate = proxy.convert(value.location, from: .global) else { return }
                                                    moveWaypoint(withID: waypoint.id, to: coordinate)
                                                }
                                        )
                                }
                            }

                            if usesPointPicker, let selectedCoordinate {
                                Marker("New", coordinate: selectedCoordinate)
                                    .tint(.red)
                            }
                        }
                        .mapStyle(.hybrid(elevation: .realistic))
                        .onMapCameraChange(frequency: .continuous) { context in
                            visibleRegion = context.region
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onEnded { value in
                            // Treat short drag as a mouse click so macOS interaction is predictable.
                            let deltaX = value.location.x - value.startLocation.x
                            let deltaY = value.location.y - value.startLocation.y
                            let movedDistance = sqrt((deltaX * deltaX) + (deltaY * deltaY))
                            guard movedDistance < 4 else { return }

                            if let coordinate = proxy.convert(value.location, from: .local) {
                                handleMapTap(coordinate)
                            }
                        })
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
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                if usesPointPicker {
                    Button("Use Point") {
                        guard let selectedCoordinate else { return }
                        onConfirm(.point(selectedCoordinate))
                        dismiss()
                    }
                    .disabled(selectedCoordinate == nil)
                } else {
                    Button("Use Waypoints") {
                        onConfirm(.waypoints(editableWaypoints))
                        dismiss()
                    }
                    .disabled(editableWaypoints.count < 2)
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var selectionText: String {
        if usesPointPicker {
            guard let selectedCoordinate else {
                return "Linksklick auf die Karte, um eine Koordinate zu setzen."
            }
            return String(
                format: "Selected: %.6f, %.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                selectedCoordinate.latitude,
                selectedCoordinate.longitude
            )
        }

        if let movingWaypointID,
           let index = editableWaypoints.firstIndex(where: { $0.id == movingWaypointID }) {
            return "Move mode: waypoint \(index + 1). Linksklick auf die Karte, um ihn zu verschieben."
        }

        if !isAddModeEnabled {
            return "Kein Modus aktiv. Add Mode einschalten oder einen Waypoint zum Verschieben auswaehlen."
        }

        return "Add mode: Linksklick auf die Karte, um einen neuen Waypoint anzufuegen."
    }

    private var displayedWaypoints: [GeoPoint] {
        usesWaypointEditor ? editableWaypoints : existingWaypoints
    }

    private var displayedWaypointsCoordinates: [CLLocationCoordinate2D] {
        displayedWaypoints.map { waypoint in
            CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)
        }
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
            .help("Zoom in")

            Button {
                zoomMap(by: 2.0)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Zoom out")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    @ViewBuilder
    private var waypointEditorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waypoints")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if isAddModeEnabled {
                    Button("Add Mode") {
                        isAddModeEnabled = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button("Add Mode") {
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
                                    locale: Locale(identifier: "en_US_POSIX"),
                                    waypoint.lat,
                                    waypoint.lon
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)

                            Spacer()

                            Button(movingWaypointID == waypoint.id ? "Moving..." : "Move") {
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
                searchStatusMessage = "Kein Treffer fuer \"\(query)\" gefunden."
                isSearching = false
                return
            }

            let coordinate = first.location.coordinate
            centerMap(on: coordinate)
            searchStatusMessage = first.name
                ?? first.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? "Treffer gefunden"
        } catch {
            searchStatusMessage = "Suche fehlgeschlagen: \(error.localizedDescription)"
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
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(isSelected ? Color.orange : Color.blue)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            )
    }
}
