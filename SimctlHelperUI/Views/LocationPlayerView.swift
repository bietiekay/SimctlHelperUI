import SwiftUI
import UniformTypeIdentifiers
import MapKit

struct LocationPlayerView: View {
    @StateObject var viewModel: LocationPlayerViewModel
    @State private var showGPXImporter = false
    @State private var showLibraryImporter = false
    @State private var showLibraryExporter = false
    @State private var mapPickerContext: MapPickerContext?
    @State private var selectedLocationID: UUID?
    @State private var selectedRouteID: UUID?
    @State private var locationDraft: SavedLocation?
    @State private var routeDraft: SavedRoute?
    @State private var isSyncingSelection = false
    @State private var libraryExportDocument = LocationLibraryDocument(data: Data())
    @State private var importSelectionContext: ImportSelectionContext?

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

            Divider()
            playbackControls
        }
        .navigationTitle("Location Player - \(viewModel.deviceName)")
        .onAppear {
            viewModel.start()
            syncSelectionFromViewModel()
        }
        .onDisappear {
            viewModel.handleWindowClose()
        }
        .onChange(of: selectedLocationID) { _, value in
            guard !isSyncingSelection else { return }
            viewModel.selectLocation(value)
            syncSelectionFromViewModel()
        }
        .onChange(of: selectedRouteID) { _, value in
            guard !isSyncingSelection else { return }
            viewModel.selectRoute(value)
            syncSelectionFromViewModel()
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
        .fileImporter(
            isPresented: $showGPXImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else { return }
                viewModel.importRoute(from: fileURL)
                syncSelectionFromViewModel()
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showLibraryImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else { return }
                guard let importedLibrary = viewModel.importLibrary(from: fileURL) else { return }
                importSelectionContext = ImportSelectionContext(library: importedLibrary)
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
            Text("Location Player - \(viewModel.deviceName)")
                .font(.headline)
            Text("UDID: \(viewModel.udid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            HStack {
                Circle()
                    .fill(viewModel.isDeviceBooted ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(viewModel.isDeviceBooted ? "Booted" : "Shutdown")
                    .font(.subheadline)
                    .foregroundColor(viewModel.isDeviceBooted ? .primary : .secondary)
            }
            Text("Default Location: \(viewModel.defaultLocationName)")
                .font(.caption)
                .foregroundColor(.secondary)

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
                        Button("Delete") {
                            viewModel.deleteSelectedRoute()
                            syncSelectionFromViewModel()
                        }
                        .disabled(viewModel.selectedRouteID == nil)
                        Button("Import GPX") {
                            showGPXImporter = true
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Library File") {
                HStack {
                    Button("Export All") {
                        beginLibraryExport()
                    }
                    Button("Import...") {
                        showLibraryImporter = true
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
                if let locationDraft {
                    locationDetails(location: locationDraft)
                }

                if let routeDraft {
                    routeDetails(route: routeDraft)
                }

                if locationDraft == nil && routeDraft == nil {
                    Text("Select a location or route from the library.")
                        .foregroundColor(.secondary)
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

            Button("Apply Location") {
                viewModel.applySelectedLocation()
            }
            .disabled(!viewModel.isDeviceBooted)

            Button("Edit On Map") {
                openLocationEditMapPicker(location)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func routeDetails(route: SavedRoute) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Text("Waypoints")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Edit On Map") {
                        openWaypointMapPicker()
                    }
                }

                ForEach(routeDraft?.waypoints ?? route.waypoints) { waypoint in
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
            if !viewModel.isDeviceBooted {
                Text("Simulator is not booted. Playback controls are disabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Play") {
                    viewModel.playSelectedRoute()
                }
                .disabled(!viewModel.isDeviceBooted || viewModel.selectedRouteID == nil)

                Button(pauseButtonTitle) {
                    viewModel.togglePauseResume()
                }
                .disabled(!viewModel.isDeviceBooted || !canPauseResume)

                Button("Stop") {
                    viewModel.stop()
                }
                .disabled(!viewModel.isDeviceBooted || !viewModel.canStopRoute)

                Button("Reset To Default Location") {
                    viewModel.resetToDefaultLocation()
                }
                .disabled(!viewModel.isDeviceBooted || viewModel.defaultLocationID == nil)

                Spacer()

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var canPauseResume: Bool {
        switch viewModel.playbackState {
        case .running, .paused:
            return true
        default:
            return false
        }
    }

    private var pauseButtonTitle: String {
        switch viewModel.playbackState {
        case .running:
            return "Pause"
        case .paused:
            return "Resume"
        default:
            return "Pause/Resume"
        }
    }

    private var statusText: String {
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
        viewModel.replaceLocation(draft)
    }

    private func updateRouteDraft(_ update: (inout SavedRoute) -> Void) {
        guard var draft = routeDraft else { return }
        update(&draft)
        routeDraft = draft
        viewModel.replaceRoute(draft)
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

    private func beginLibraryExport() {
        guard let data = viewModel.exportLibraryData() else { return }
        libraryExportDocument = LocationLibraryDocument(data: data)
        showLibraryExporter = true
    }

    private var libraryExportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "location-library-\(formatter.string(from: Date()))"
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
        var request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = visibleRegion
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let first = response.mapItems.first,
                  let coordinate = first.placemark.location?.coordinate else {
                searchStatusMessage = "Kein Treffer fuer \"\(query)\" gefunden."
                isSearching = false
                return
            }

            centerMap(on: coordinate)
            searchStatusMessage = first.name ?? first.placemark.title ?? "Treffer gefunden"
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
