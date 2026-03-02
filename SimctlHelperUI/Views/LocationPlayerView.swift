import SwiftUI
import UniformTypeIdentifiers

struct LocationPlayerView: View {
    @StateObject var viewModel: LocationPlayerViewModel
    @State private var showGPXImporter = false
    @State private var selectedLocationID: UUID?
    @State private var selectedRouteID: UUID?
    @State private var locationDraft: SavedLocation?
    @State private var routeDraft: SavedRoute?
    @State private var isSyncingSelection = false

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
                            viewModel.addLocation()
                            syncSelectionFromViewModel()
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
                    Button("Add Waypoint") {
                        updateRouteDraft { draft in
                            draft.waypoints.append(GeoPoint(lat: 0, lon: 0))
                        }
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
}
