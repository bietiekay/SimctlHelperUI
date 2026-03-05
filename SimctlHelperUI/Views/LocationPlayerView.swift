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
    @State private var libraryExportDocument = LocationLibraryDocument(data: Data())
    @State private var renameContext: RenameContext?
    @State private var pendingLocationSaveTask: Task<Void, Never>?
    @State private var pendingRouteSaveTask: Task<Void, Never>?
    @State private var isDebugLogExpanded = false
    @State private var locationPlayerWindowIdentifier: String?
    @State private var owningWindow: NSWindow?

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
    private let mapWaypointEditingLimit = 3_000
    private var locationPlayerMinimumSize: NSSize {
        LocationPlayerWindowCoordinator.locationPlayerDefaultSize
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            HSplitView {
                libraryPanel
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)

                detailPanel
                    .frame(minWidth: 500, maxWidth: .infinity)
            }
            .layoutPriority(1)

            Divider()
            playbackControls
        }
        .frame(
            minWidth: locationPlayerMinimumSize.width,
            minHeight: locationPlayerMinimumSize.height
        )
        .navigationTitle(L10n.f("Location Player - %@", viewModel.deviceName))
        .background(Color(NSColor.windowBackgroundColor))
        .background(
            WindowObserverView { window in
                DispatchQueue.main.async {
                    resolveOwningWindow(window)
                }
            }
        )
        .focusedSceneValue(
            \.locationPlayerMenuActions,
            LocationPlayerMenuActions(
                importGPXRoute: { beginGPXRouteImport() },
                importLibraryJSON: { beginLibraryImport() },
                exportLibraryJSON: { beginLibraryExport() }
            )
        )
        .onAppear {
            viewModel.start()
            ensureLibrarySelection()
            syncSelectionFromViewModel()
            processPendingMenuCommand()
        }
        .onDisappear {
            viewModel.handleWindowClose()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationPlayerMenuCommandQueued)) { _ in
            processPendingMenuCommand()
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
                    openGPXPreviewWindow(preview: preview)
                case .library:
                    guard let importedLibrary = viewModel.importLibrary(from: fileURL) else { return }
                    openLibraryImportSelectionWindow(library: importedLibrary)
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

    @MainActor
    private func resolveOwningWindow(_ window: NSWindow) {
        let resolvedIdentifier = window.identifier?.rawValue
        if locationPlayerWindowIdentifier != resolvedIdentifier {
            locationPlayerWindowIdentifier = resolvedIdentifier
        }
        if owningWindow !== window {
            owningWindow = window
        }
        processPendingMenuCommand()
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.t("Target Device"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker(
                    L10n.t("Target Device"),
                    selection: Binding(
                        get: { viewModel.udid },
                        set: { viewModel.selectTargetDevice($0) }
                    )
                ) {
                    if viewModel.availableDevices.isEmpty {
                        Text(L10n.t("No devices found")).tag("")
                    } else {
                        ForEach(viewModel.availableDevices) { device in
                            Text(
                                L10n.f(
                                    "%@ (%@)",
                                    device.name,
                                    device.isBooted ? L10n.t("Booted") : L10n.t("Shutdown")
                                )
                            )
                                .tag(device.udid)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 300)
                .disabled(viewModel.availableDevices.isEmpty)

                Toggle(L10n.t("Auto-Boot on Send"), isOn: $viewModel.autoBootOnSend)
                    .toggleStyle(.checkbox)

                Spacer()
            }

            HStack(spacing: 12) {
                Text(L10n.f("UDID: %@", viewModel.udid))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isDeviceBooted ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isDeviceBooted ? L10n.t("Booted") : L10n.t("Shutdown"))
                        .font(.caption)
                        .foregroundColor(viewModel.isDeviceBooted ? .primary : .secondary)
                }

                Text(L10n.f("Default: %@", viewModel.defaultLocationName))
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
        .padding(12)
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $librarySelection) {
                Section(L10n.t("Locations")) {
                    ForEach(viewModel.locations) { location in
                        HStack {
                            Text(location.name)
                            Spacer()
                            if viewModel.defaultLocationID == location.id {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                            }
                        }
                        .tag(LibrarySelection.location(location.id))
                    }
                }

                Section(L10n.t("Routes")) {
                    ForEach(viewModel.routes) { route in
                        Text(route.name)
                            .tag(LibrarySelection.route(route.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
            .frame(minHeight: 220)

            GroupBox(L10n.t("Location Actions")) {
                HStack {
                    Button(L10n.t("Add")) {
                        openLocationMapPicker()
                    }
                    Button(L10n.t("Rename")) {
                        beginRenameSelectedLocation()
                    }
                    .disabled(viewModel.selectedLocationID == nil)
                    Button(L10n.t("Delete")) {
                        viewModel.deleteSelectedLocation()
                        syncSelectionFromViewModel()
                    }
                    .disabled(viewModel.selectedLocationID == nil)
                    Button(L10n.t("Set Default")) {
                        viewModel.setDefaultLocationToSelection()
                    }
                    .disabled(viewModel.selectedLocationID == nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(L10n.t("Route Actions")) {
                HStack {
                    Button(L10n.t("Add")) {
                        viewModel.addRoute()
                        syncSelectionFromViewModel()
                    }
                    Button(L10n.t("Rename")) {
                        beginRenameSelectedRoute()
                    }
                    .disabled(viewModel.selectedRouteID == nil)
                    Button(L10n.t("Delete")) {
                        viewModel.deleteSelectedRoute()
                        syncSelectionFromViewModel()
                    }
                    .disabled(viewModel.selectedRouteID == nil)
                    Button(L10n.t("Import GPX")) {
                        beginGPXRouteImport()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(L10n.t("Library File")) {
                HStack {
                    Button(L10n.t("Export All")) {
                        beginLibraryExport()
                    }
                    Button(L10n.t("Import...")) {
                        beginLibraryImport()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(12)
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
                            .foregroundColor(.secondary)
                    }
                case .route:
                    if let routeDraft {
                        routeDetails(route: routeDraft)
                    } else {
                        Text(L10n.t("Select a route from the library."))
                            .foregroundColor(.secondary)
                    }
                case .none:
                    Text(L10n.t("Select a location or route from the library."))
                        .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
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
                        switch selection {
                        case 0:
                            route.updateMode = .interval(seconds: 1)
                        default:
                            route.updateMode = .distance(meters: 10)
                        }
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
                            .foregroundColor(.secondary)
                        if let first = waypoints.first, let last = waypoints.last {
                            Text(
                                String(
                                    format: L10n.t("Start: %.6f, %.6f  |  End: %.6f, %.6f"),
                                    locale: Locale.current,
                                    first.lat, first.lon, last.lat, last.lon
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        }
                        Text(L10n.f("+ %d additional waypoints hidden in direct editor.", hiddenWaypointCount))
                            .font(.caption)
                            .foregroundColor(.secondary)
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
        .cornerRadius(8)
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.hasTargetDevice {
                Text(L10n.t("No target simulator selected."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !viewModel.isDeviceBooted, viewModel.autoBootOnSend {
                Text(L10n.t("Selected simulator is shutdown. Actions will boot it automatically."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !viewModel.isDeviceBooted {
                Text(L10n.t("Selected simulator is shutdown."))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!viewModel.hasTargetDevice)

                    Button(L10n.t("Reset To Default Location")) {
                        flushLocationDraftSave()
                        viewModel.resetToDefaultLocation()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!viewModel.hasTargetDevice || viewModel.defaultLocationID == nil)

                    Spacer()

                    Text(L10n.t("Single location mode"))
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    .buttonStyle(.borderedProminent)
                    .tint(pauseResumeButtonTint)
                    .disabled(isPauseDisabled)

                    Button(L10n.t("Stop")) {
                        viewModel.stop()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
                            Button(L10n.t("Copy Log")) {
                                copyDebugLogToClipboard()
                            }
                            .disabled(viewModel.debugLogText.isEmpty)

                            Button(L10n.t("Clear Log")) {
                                viewModel.clearDebugLog()
                            }

                            Button(L10n.t("Refresh")) {
                                viewModel.refreshDebugLog()
                            }

                            Spacer()
                        }

                        ScrollView {
                            Text(viewModel.debugLogText.isEmpty ? L10n.t("No debug entries yet.") : viewModel.debugLogText)
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
                        Text(L10n.t("Debug Log"))
                        Spacer()
                        Text(L10n.f("%d lines", viewModel.debugLogLineCount))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var isRouteSelection: Bool {
        librarySelection?.routeID != nil
    }

    private var canPauseResume: Bool {
        guard isRouteSelection else {
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
        guard isRouteSelection else {
            return L10n.t("Pause")
        }
        switch viewModel.playbackState {
        case .running:
            return L10n.t("Pause")
        case .paused:
            return L10n.t("Resume")
        default:
            return L10n.t("Pause/Resume")
        }
    }

    private var pauseResumeButtonTint: Color {
        switch viewModel.playbackState {
        case .paused:
            return .blue
        default:
            return .orange
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
        !viewModel.hasTargetDevice || !canPauseResume
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

        openCoordinatePickerWindow(MapPickerContext(
            mode: .addLocation,
            title: L10n.t("Choose Location Point"),
            subtitle: L10n.t("Click on the map to place the new saved location."),
            initialPoint: initialPoint,
            existingWaypoints: []
        ))
    }

    private func openLocationEditMapPicker(_ location: SavedLocation) {
        openCoordinatePickerWindow(MapPickerContext(
            mode: .editLocation(locationID: location.id),
            title: L10n.t("Edit Location Point"),
            subtitle: L10n.t("Click on the map to move this location."),
            initialPoint: location.point,
            existingWaypoints: []
        ))
    }

    private func openWaypointMapPicker() {
        let existingWaypoints = routeDraft?.waypoints ?? []
        guard existingWaypoints.count <= mapWaypointEditingLimit else {
            viewModel.errorMessage = L10n.f(
                "Map waypoint editor supports up to %d waypoints. Reduce route size first.",
                mapWaypointEditingLimit
            )
            return
        }
        let initialPoint = existingWaypoints.last
            ?? locationDraft?.point
            ?? viewModel.locations.first?.point
            ?? GeoPoint(lat: 37.3349, lon: -122.0090)

        openCoordinatePickerWindow(MapPickerContext(
            mode: .editWaypoints,
            title: L10n.t("Edit Waypoints"),
            subtitle: L10n.t("Select a waypoint to move, or add a new one by clicking on the map."),
            initialPoint: initialPoint,
            existingWaypoints: existingWaypoints
        ))
    }

    private func copyDebugLogToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.debugLogShareText, forType: .string)
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
        libraryExportDocument = LocationLibraryDocument(data: data)
        showLibraryExporter = true
    }

    private func openCoordinatePickerWindow(_ context: MapPickerContext) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .mapEditor,
            ownerWindowIdentifier: locationPlayerWindowIdentifier,
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
            ownerWindowIdentifier: locationPlayerWindowIdentifier,
            title: L10n.t("Import Selection"),
            parentWindow: owningWindow
        ) { close in
            LibraryImportSelectionSheet(library: library, onClose: close) { selectedLocationIDs, selectedRouteIDs in
                viewModel.importSelection(
                    locationIDs: selectedLocationIDs,
                    routeIDs: selectedRouteIDs,
                    from: library
                )
                syncSelectionFromViewModel()
            }
        }
    }

    private func openGPXPreviewWindow(preview: GPXImportPreview) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .gpxPreview,
            ownerWindowIdentifier: locationPlayerWindowIdentifier,
            title: L10n.t("Import GPX"),
            parentWindow: owningWindow
        ) { close in
            GPXImportPreviewSheet(preview: preview, onClose: close) { selectedTimeRange, selectedPointRange in
                viewModel.importRoute(
                    from: preview,
                    selectedTimeRange: selectedTimeRange,
                    selectedPointRange: selectedPointRange
                )
                syncSelectionFromViewModel()
            }
        }
    }

    private func processPendingMenuCommand() {
        guard let command = LocationPlayerMenuCommandCenter.shared.consumeCommand(
            for: locationPlayerWindowIdentifier
        ) else {
            return
        }

        switch command {
        case .importGPXRoute:
            beginGPXRouteImport()
        case .importLibraryJSON:
            beginLibraryImport()
        case .exportLibraryJSON:
            beginLibraryExport()
        }
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

private struct LocationPreviewMap: NSViewRepresentable {
    let locationID: UUID
    let point: GeoPoint
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.mapType = .hybrid
        mapView.showsCompass = true
        mapView.showsScale = false
        mapView.showsZoomControls = true
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.annotationReuseIdentifier)
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
        let markerTitle = resolvedTitle
        let previewKey = Self.previewKey(locationID: locationID, point: point)

        let annotation: MKPointAnnotation
        if let existingAnnotation = context.coordinator.annotation {
            annotation = existingAnnotation
        } else {
            let newAnnotation = MKPointAnnotation()
            context.coordinator.annotation = newAnnotation
            mapView.addAnnotation(newAnnotation)
            annotation = newAnnotation
        }

        if annotation.title != markerTitle {
            annotation.title = markerTitle
        }

        if annotation.coordinate.latitude != coordinate.latitude
            || annotation.coordinate.longitude != coordinate.longitude {
            annotation.coordinate = coordinate
        }

        if context.coordinator.lastPreviewKey != previewKey {
            mapView.setRegion(Self.region(for: point), animated: false)
            context.coordinator.lastPreviewKey = previewKey
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let annotationReuseIdentifier = "LocationPreviewPin"

        var annotation: MKPointAnnotation?
        var lastPreviewKey: String?

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.annotationReuseIdentifier,
                for: annotation
            ) as? MKMarkerAnnotationView
            view?.markerTintColor = .systemRed
            view?.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
            return view
        }
    }

    private var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.t("Selected Location") : trimmed
    }

    private static func previewKey(locationID: UUID, point: GeoPoint) -> String {
        let lat = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.lat)
        let lon = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.lon)
        return "\(locationID.uuidString)-\(lat)-\(lon)"
    }

    private static func region(for point: GeoPoint) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }
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
            return L10n.t("Rename Location")
        case .route:
            return L10n.t("Rename Route")
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

            TextField(L10n.t("Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(L10n.t("Cancel")) {
                    dismiss()
                }
                Button(L10n.t("Save")) {
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
    let onClose: (() -> Void)?
    let onImport: (ClosedRange<Date>?, ClosedRange<Int>?) -> Void

    @State private var selectedStartFraction: Double
    @State private var selectedEndFraction: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion

    init(
        preview: GPXImportPreview,
        onClose: (() -> Void)? = nil,
        onImport: @escaping (ClosedRange<Date>?, ClosedRange<Int>?) -> Void
    ) {
        self.preview = preview
        self.onClose = onClose
        self.onImport = onImport

        let defaultRegion = GPXImportPreviewSheet.mapRegion(for: preview.points.map(\.point))
        _cameraPosition = State(initialValue: .region(defaultRegion))
        _visibleRegion = State(initialValue: defaultRegion)
        _selectedStartFraction = State(initialValue: 0)
        _selectedEndFraction = State(initialValue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Import GPX"))
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
                    Marker(L10n.t("Start"), coordinate: first)
                        .tint(.green)
                }

                if let last = selectedCoordinates.last {
                    Marker(L10n.t("End"), coordinate: last)
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
                Text(preview.canSelectTimeRange ? L10n.t("Time Range") : L10n.t("Waypoint Range"))
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
                Text(L10n.t("At least two points are required in the selected range."))
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(L10n.t("Cancel")) {
                    close()
                }
                Button(L10n.t("Import Selection")) {
                    onImport(
                        preview.canSelectTimeRange ? selectedTimeRange : nil,
                        preview.canSelectTimeRange ? nil : selectedPointRange
                    )
                    close()
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
            return L10n.f("%d points, duration: %@", preview.totalPointCount, formattedDuration(duration))
        }
        return L10n.f("%d points (without timestamps)", preview.totalPointCount)
    }

    private var selectionSummaryText: String {
        let base = L10n.f("%d of %d points in import range", selectedPoints.count, preview.totalPointCount)
        if let selectedTimeRange {
            let duration = selectedTimeRange.upperBound.timeIntervalSince(selectedTimeRange.lowerBound)
            return "\(base) (\(formattedDuration(duration)))"
        }
        if let selectedPointRange {
            return L10n.f(
                "%@ (WP %d-%d)",
                base,
                selectedPointRange.lowerBound + 1,
                selectedPointRange.upperBound + 1
            )
        }
        return base
    }

    private var selectedRangeStartText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.lowerBound)
        }
        if let selectedPointRange {
            return L10n.f("WP %d", selectedPointRange.lowerBound + 1)
        }
        return L10n.t("WP 1")
    }

    private var selectedRangeEndText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.upperBound)
        }
        if let selectedPointRange {
            return L10n.f("WP %d", selectedPointRange.upperBound + 1)
        }
        return L10n.t("WP 1")
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
        guard let date else { return L10n.t("n/a") }
        return Self.dateFormatter.string(from: date)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let resolved = max(0, duration)
        return Self.durationFormatter.string(from: resolved) ?? String(format: L10n.t("%.0fs"), resolved)
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

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
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
    let onClose: (() -> Void)?
    let onImport: (Set<UUID>, Set<UUID>) -> Void

    @State private var selectedLocationIDs: Set<UUID>
    @State private var selectedRouteIDs: Set<UUID>

    init(
        library: LocationLibrary,
        onClose: (() -> Void)? = nil,
        onImport: @escaping (Set<UUID>, Set<UUID>) -> Void
    ) {
        self.library = library
        self.onClose = onClose
        self.onImport = onImport
        _selectedLocationIDs = State(initialValue: Set(library.locations.map(\.id)))
        _selectedRouteIDs = State(initialValue: Set(library.routes.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Import Selection"))
                .font(.headline)
            Text(L10n.t("Choose which locations and routes should be imported."))
                .font(.caption)
                .foregroundColor(.secondary)

            GroupBox(L10n.f("Locations (%d/%d)", selectedLocationIDs.count, library.locations.count)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(L10n.t("All")) {
                            selectedLocationIDs = Set(library.locations.map(\.id))
                        }
                        Button(L10n.t("None")) {
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

            GroupBox(L10n.f("Routes (%d/%d)", selectedRouteIDs.count, library.routes.count)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(L10n.t("All")) {
                            selectedRouteIDs = Set(library.routes.map(\.id))
                        }
                        Button(L10n.t("None")) {
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
                Button(L10n.t("Cancel")) {
                    close()
                }
                Button(L10n.t("Import Selection")) {
                    onImport(selectedLocationIDs, selectedRouteIDs)
                    close()
                }
                .disabled(selectedLocationIDs.isEmpty && selectedRouteIDs.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
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
                        TextField(L10n.t("Search place (e.g. Berlin Central Station)"), text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                runLocationSearch()
                            }

                        Button(L10n.t("Search")) {
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

                    if let waypointSamplingStatusText {
                        Text(waypointSamplingStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
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

        // Keep rendering aggressively capped for performance until the user is very close.
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
                            .foregroundColor(.secondary)

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
            .foregroundColor(.white)
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
