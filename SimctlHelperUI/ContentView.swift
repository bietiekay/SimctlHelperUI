//
//  ContentView.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum FileImportKind {
        case gpx
        case library
    }

    private static let backgroundRefreshIntervalNanoseconds: UInt64 = 10_000_000_000

    @Environment(\.openWindow) private var openWindow

    @ObservedObject var deviceStore: DeviceStore
    @ObservedObject var libraryController: LocationLibraryController

    @State private var selectedDeviceID: String?
    @State private var searchText = ""
    @State private var filter: DeviceFilter = .all
    @State private var isInspectorPresented = true
    @State private var showDeleteUnavailableConfirmation = false
    @State private var cloneTarget: DeviceRecord?
    @State private var deleteTarget: DeviceRecord?
    @State private var activeFileImportKind: FileImportKind?
    @State private var isFileImporterPresented = false
    @State private var showLibraryExporter = false
    @State private var libraryExportDocument = LocationLibraryTransferDocument(data: Data())
    @State private var windowIdentifier: String?
    @State private var owningWindow: NSWindow?

    private var selectedDevice: DeviceRecord? {
        guard let selectedDeviceID else { return nil }
        return filteredDevices.first(where: { $0.id == selectedDeviceID }) ?? deviceStore.device(for: selectedDeviceID)
    }

    private var visibleFeedback: FeedbackMessage? {
        libraryController.feedback ?? deviceStore.feedback
    }

    private var filteredDevices: [DeviceRecord] {
        deviceStore.devices.filter { device in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .booted:
                matchesFilter = device.isBooted
            case .unavailable:
                matchesFilter = !device.isAvailable
            }

            guard matchesFilter else { return false }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }

            let haystack = [
                device.name,
                device.udid,
                device.deviceTypeName,
                device.runtimeName,
                device.state.displayName,
            ].joined(separator: " ")

            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        content
            .frame(minWidth: 940, minHeight: 620)
            .background(
                WindowObserverView { window in
                    DispatchQueue.main.async {
                        resolveOwningWindow(window)
                    }
                }
            )
            .toolbar {
                ToolbarItemGroup {
                    Picker(L10n.t("Filter"), selection: $filter) {
                        ForEach(DeviceFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    Menu {
                        Section(L10n.t("Sort")) {
                            ForEach(DeviceSortKey.allCases) { key in
                                Button {
                                    deviceStore.setSortKey(key)
                                } label: {
                                    HStack {
                                        Text(key.title)
                                        if deviceStore.sortKey == key {
                                            Image(systemName: deviceStore.sortDirection == .ascending ? "arrow.up" : "arrow.down")
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(isInspectorPresented ? L10n.t("Hide Inspector") : L10n.t("Show Inspector")) {
                            isInspectorPresented.toggle()
                        }

                        if deviceStore.hasUnavailableDevices {
                            Divider()

                            Button(L10n.t("Delete Unavailable Simulators"), role: .destructive) {
                                showDeleteUnavailableConfirmation = true
                            }
                        }
                    } label: {
                        Label(L10n.t("View Options"), systemImage: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: L10n.t("Search Simulators"))
            .focusedSceneValue(
                \.libraryMenuActions,
                LibraryMenuActions(
                    importGPXRoute: { beginGPXRouteImport() },
                    importLibraryJSON: { beginLibraryImport() },
                    exportLibraryJSON: { beginLibraryExport() }
                )
            )
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.backgroundRefreshIntervalNanoseconds)
                    await deviceStore.refreshDevicesInBackground()
                }
            }
            .sheet(item: $cloneTarget) { device in
                CloneDeviceView(
                    isPresented: Binding(
                        get: { cloneTarget != nil },
                        set: { isPresented in
                            if !isPresented {
                                cloneTarget = nil
                            }
                        }
                    ),
                    deviceName: device.name
                ) { newName in
                    try await deviceStore.cloneDevice(udid: device.udid, name: newName)
                }
            }
            .alert(L10n.t("Delete Unavailable Simulators"), isPresented: $showDeleteUnavailableConfirmation) {
                Button(L10n.t("Cancel"), role: .cancel) {}
                Button(L10n.t("Delete All"), role: .destructive) {
                    Task {
                        do {
                            try await deviceStore.deleteUnavailableDevices()
                        } catch {
                            deviceStore.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
                        }
                    }
                }
            } message: {
                Text(L10n.t("This removes all unavailable simulators from the current list."))
            }
            .alert(
                L10n.t("Delete Device"),
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { isPresented in
                        if !isPresented {
                            deleteTarget = nil
                        }
                    }
                ),
                presenting: deleteTarget
            ) { device in
                Button(L10n.t("Cancel"), role: .cancel) {}
                Button(L10n.t("Delete"), role: .destructive) {
                    Task {
                        do {
                            try await deviceStore.deleteDevice(udid: device.udid)
                        } catch {
                            deviceStore.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
                        }
                    }
                }
            } message: { device in
                Text(L10n.f("Are you sure you want to delete \"%@\"? This action cannot be undone.", device.name))
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
                        guard let preview = libraryController.prepareGPXImport(from: fileURL) else { return }
                        openGPXPreviewWindow(preview: preview)
                    case .library:
                        guard let importedLibrary = libraryController.importLibrary(from: fileURL) else { return }
                        openLibraryImportSelectionWindow(library: importedLibrary)
                    case .none:
                        break
                    }
                case .failure(let error):
                    libraryController.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
                }
            }
            .fileExporter(
                isPresented: $showLibraryExporter,
                document: libraryExportDocument,
                contentType: .json,
                defaultFilename: libraryExportFilename
            ) { result in
                if case .failure(let error) = result {
                    libraryController.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
                }
            }
    }

    private var content: some View {
        deviceTable
            .overlay(alignment: .top) {
                if let visibleFeedback {
                    FeedbackBannerView(message: visibleFeedback)
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                }
            }
            .inspector(isPresented: $isInspectorPresented) {
                DeviceInspectorView(
                    selectedDevice: selectedDevice,
                    onOpenControls: openSelectedDeviceControls,
                    onToggleBoot: toggleSelectedBootState,
                    onClone: { cloneTarget = selectedDevice },
                    onDelete: { deleteTarget = selectedDevice },
                    onCopyUDID: copySelectedUDID
                )
            }
    }

    @ViewBuilder
    private var deviceTable: some View {
        if filteredDevices.isEmpty && !deviceStore.isLoading {
            emptyStateView
        } else {
            Table(filteredDevices, selection: selectionBinding) {
                TableColumn(L10n.t("Name")) { device in
                    DeviceNameCell(device: device)
                }
                .width(min: 220, ideal: 280)

                TableColumn(L10n.t("State")) { device in
                    Text(device.state.displayName)
                }
                .width(min: 90, ideal: 110)

                TableColumn(L10n.t("Availability")) { device in
                    DeviceAvailabilityCell(device: device)
                }
                .width(min: 100, ideal: 120)

                TableColumn(L10n.t("Device Type")) { device in
                    Text(device.deviceTypeName)
                }
                .width(min: 180, ideal: 220)

                TableColumn(L10n.t("Runtime")) { device in
                    Text(device.runtimeName)
                }
                .width(min: 120, ideal: 160)
            }
            .contextMenu(forSelectionType: String.self) { selectedIDs in
                if let selectedID = selectedIDs.first,
                   let device = deviceStore.device(for: selectedID) {
                    Button(L10n.t("Open Controls")) {
                        openControls(for: device.udid)
                    }

                    Button(device.isBooted ? L10n.t("Shutdown") : L10n.t("Boot")) {
                        performBootToggle(for: device)
                    }

                    Button(L10n.t("Clone Device")) {
                        cloneTarget = device
                    }

                    Button(L10n.t("Copy UDID")) {
                        copyUDID(device.udid)
                    }

                    Divider()

                    Button(L10n.t("Delete Device"), role: .destructive) {
                        deleteTarget = device
                    }
                }
            } primaryAction: { selectedIDs in
                guard let selectedID = selectedIDs.first,
                      let device = deviceStore.device(for: selectedID) else {
                    return
                }
                openControls(for: device.udid)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedDeviceID },
            set: { selectedDeviceID = $0 }
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.t("No devices found") : L10n.t("No simulators match the current filter."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    @MainActor
    private func resolveOwningWindow(_ window: NSWindow) {
        let resolvedIdentifier = window.identifier?.rawValue
        if windowIdentifier == resolvedIdentifier, owningWindow === window {
            return
        }

        windowIdentifier = resolvedIdentifier
        owningWindow = window
    }

    private func openSelectedDeviceControls() {
        guard let selectedDevice else { return }
        openControls(for: selectedDevice.udid)
    }

    private func openControls(for udid: String) {
        LocationPlayerWindowCoordinator.openOrFocusWindow(for: udid, openWindow: openWindow)
    }

    private func toggleSelectedBootState() {
        guard let selectedDevice else { return }
        performBootToggle(for: selectedDevice)
    }

    private func performBootToggle(for device: DeviceRecord) {
        Task {
            do {
                if device.isBooted {
                    try await deviceStore.shutdownDevice(udid: device.udid)
                } else {
                    try await deviceStore.bootDevice(udid: device.udid)
                }
            } catch {
                deviceStore.feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    private func copySelectedUDID() {
        guard let selectedDevice else { return }
        copyUDID(selectedDevice.udid)
    }

    private func copyUDID(_ udid: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(udid, forType: .string)
        deviceStore.feedback = FeedbackMessage(level: .info, text: L10n.t("UDID copied to clipboard."))
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
        guard let data = libraryController.exportLibraryData() else { return }
        libraryExportDocument = LocationLibraryTransferDocument(data: data)
        showLibraryExporter = true
    }

    private func openLibraryImportSelectionWindow(library: LocationLibrary) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .importSelection,
            ownerWindowIdentifier: windowIdentifier,
            title: L10n.t("Import Selection"),
            parentWindow: owningWindow
        ) { close in
            LibraryImportSelectionView(library: library, onClose: close) { selectedLocationIDs, selectedRouteIDs in
                libraryController.importSelection(
                    locationIDs: selectedLocationIDs,
                    routeIDs: selectedRouteIDs,
                    from: library
                )
            }
        }
    }

    private func openGPXPreviewWindow(preview: GPXImportPreview) {
        LocationPlayerAuxWindowCoordinator.shared.present(
            kind: .gpxPreview,
            ownerWindowIdentifier: windowIdentifier,
            title: L10n.t("Import GPX"),
            parentWindow: owningWindow
        ) { close in
            GPXImportPreviewWindowView(preview: preview, onClose: close) { selectedTimeRange, selectedPointRange in
                _ = libraryController.importRoute(
                    from: preview,
                    selectedTimeRange: selectedTimeRange,
                    selectedPointRange: selectedPointRange
                )
            }
        }
    }

    private var libraryExportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "location-library-\(formatter.string(from: Date()))"
    }
}

struct DeviceNameCell: View {
    let device: DeviceRecord

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(device.isBooted ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(device.name)
        }
    }
}

struct DeviceAvailabilityCell: View {
    let device: DeviceRecord

    var body: some View {
        Text(device.availabilityText)
            .foregroundColor(device.isAvailable ? .primary : .secondary)
    }
}

#Preview {
    ContentView(deviceStore: .shared, libraryController: .shared)
}
