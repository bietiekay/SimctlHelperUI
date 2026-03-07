//
//  SimctlHelperUIApp.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI
import AppKit

@MainActor
struct LibraryMenuActions {
    let importGPXRoute: () -> Void
    let importLibraryJSON: () -> Void
    let exportLibraryJSON: () -> Void
}

private struct LibraryMenuActionsKey: FocusedValueKey {
    typealias Value = LibraryMenuActions
}

extension FocusedValues {
    var libraryMenuActions: LibraryMenuActions? {
        get { self[LibraryMenuActionsKey.self] }
        set { self[LibraryMenuActionsKey.self] = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SimctlHelperUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var deviceStore = DeviceStore.shared
    @StateObject private var libraryController = LocationLibraryController.shared

    var body: some Scene {
        Window(L10n.t("Device Overview"), id: "main") {
            ContentView(deviceStore: deviceStore, libraryController: libraryController)
                .background(
                    WindowObserverView { window in
                        LocationPlayerWindowCoordinator.assignMainWindowIdentifier(to: window)
                    }
                )
        }
        .defaultSize(width: 1180, height: 760)

        WindowGroup(L10n.t("Location Simulation"), id: "location-player", for: String.self) { udid in
            LocationSimulationSceneView(
                initialUDID: udid.wrappedValue,
                deviceStore: deviceStore,
                libraryController: libraryController
            )
        }
        .defaultSize(
            width: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.width,
            height: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.height
        )
        .windowResizability(.contentMinSize)

        Window(L10n.t("Diagnostics"), id: "diagnostics") {
            DiagnosticsWindowView()
        }
        .defaultSize(width: 880, height: 520)
        .commands {
            AppCommandSet()
        }
    }
}

private struct LocationSimulationSceneView: View {
    @StateObject private var viewModel: LocationPlayerViewModel

    init(
        initialUDID: String?,
        deviceStore: DeviceStore,
        libraryController: LocationLibraryController
    ) {
        _viewModel = StateObject(
            wrappedValue: LocationPlayerViewModel(
                targetUDID: initialUDID,
                deviceStore: deviceStore,
                libraryController: libraryController
            )
        )
    }

    var body: some View {
        LocationPlayerView(viewModel: viewModel)
            .background(
                WindowObserverView { window in
                    LocationPlayerWindowCoordinator.assignIdentifier(to: window, udid: viewModel.targetUDID)
                    LocationPlayerWindowCoordinator.installCloseBehavior(on: window) {
                        viewModel.handleCloseRequest()
                    }
                }
            )
    }
}

private struct AppCommandSet: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.libraryMenuActions) private var libraryMenuActions

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Divider()

            Button(L10n.t("Import GPX Route...")) {
                libraryMenuActions?.importGPXRoute()
            }
            .disabled(libraryMenuActions == nil)

            Button(L10n.t("Import Location/Route Library...")) {
                libraryMenuActions?.importLibraryJSON()
            }
            .disabled(libraryMenuActions == nil)

            Button(L10n.t("Export Location/Route Library...")) {
                libraryMenuActions?.exportLibraryJSON()
            }
            .disabled(libraryMenuActions == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button(L10n.t("Diagnostics")) {
                openWindow(id: "diagnostics")
            }
        }

        CommandGroup(replacing: .appTermination) {
            Button(L10n.t("Quit SimctlHelperUI")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
