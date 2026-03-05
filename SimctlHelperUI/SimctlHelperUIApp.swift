//
//  SimctlHelperUIApp.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI
import AppKit

@MainActor
struct LocationPlayerMenuActions {
    let importGPXRoute: () -> Void
    let importLibraryJSON: () -> Void
    let exportLibraryJSON: () -> Void
}

private struct LocationPlayerMenuActionsKey: FocusedValueKey {
    typealias Value = LocationPlayerMenuActions
}

extension FocusedValues {
    var locationPlayerMenuActions: LocationPlayerMenuActions? {
        get { self[LocationPlayerMenuActionsKey.self] }
        set { self[LocationPlayerMenuActionsKey.self] = newValue }
    }
}

@MainActor
enum LocationPlayerMenuCommand {
    case importGPXRoute
    case importLibraryJSON
    case exportLibraryJSON
}

extension Notification.Name {
    static let locationPlayerMenuCommandQueued = Notification.Name("LocationPlayerMenuCommandQueued")
}

@MainActor
final class LocationPlayerMenuCommandCenter {
    static let shared = LocationPlayerMenuCommandCenter()

    private var pendingCommand: LocationPlayerMenuCommand?
    private var pendingTargetWindowIdentifier: String?

    private init() {}

    func queue(
        _ command: LocationPlayerMenuCommand,
        targetWindowIdentifier: String?
    ) {
        pendingCommand = command
        pendingTargetWindowIdentifier = targetWindowIdentifier
        NotificationCenter.default.post(name: .locationPlayerMenuCommandQueued, object: nil)
    }

    func consumeCommand(for windowIdentifier: String?) -> LocationPlayerMenuCommand? {
        guard let pendingCommand else { return nil }

        if let pendingTargetWindowIdentifier,
           pendingTargetWindowIdentifier != windowIdentifier {
            return nil
        }

        self.pendingCommand = nil
        pendingTargetWindowIdentifier = nil
        return pendingCommand
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

    var body: some Scene {
        Window(L10n.t("Device Overview"), id: "main") {
            ContentView()
                .background(
                    WindowObserverView { window in
                        LocationPlayerWindowCoordinator.assignMainWindowIdentifier(to: window)
                    }
                )
        }
        .defaultSize(width: 1100, height: 700)

        WindowGroup(L10n.t("Location Player"), id: "location-player", for: String.self) { udid in
            LocationPlayerSceneView(initialUDID: udid.wrappedValue)
        }
        .defaultSize(
            width: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.width,
            height: LocationPlayerWindowCoordinator.locationPlayerDefaultSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            LocationDataCommands()
        }
    }
}

private struct LocationPlayerSceneView: View {
    @StateObject private var viewModel: LocationPlayerViewModel

    init(initialUDID: String?) {
        _viewModel = StateObject(wrappedValue: LocationPlayerViewModel(udid: initialUDID))
    }

    var body: some View {
        LocationPlayerView(viewModel: viewModel)
            .background(
                WindowObserverView { window in
                    LocationPlayerWindowCoordinator.assignIdentifier(to: window, udid: viewModel.udid)
                }
            )
            .onChange(of: viewModel.udid) { oldUDID, newUDID in
                LocationPlayerWindowCoordinator.reassignIdentifier(from: oldUDID, to: newUDID)
            }
    }
}

private struct LocationDataCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.locationPlayerMenuActions) private var locationPlayerMenuActions

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Divider()

            Button(L10n.t("Import GPX Route...")) {
                perform(.importGPXRoute)
            }

            Button(L10n.t("Import Location/Route Library...")) {
                perform(.importLibraryJSON)
            }

            Button(L10n.t("Export Location/Route Library...")) {
                perform(.exportLibraryJSON)
            }
        }

        CommandGroup(replacing: .appTermination) {
            Button(L10n.t("Quit SimctlHelperUI")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @MainActor
    private func perform(_ command: LocationPlayerMenuCommand) {
        if let locationPlayerMenuActions {
            switch command {
            case .importGPXRoute:
                locationPlayerMenuActions.importGPXRoute()
            case .importLibraryJSON:
                locationPlayerMenuActions.importLibraryJSON()
            case .exportLibraryJSON:
                locationPlayerMenuActions.exportLibraryJSON()
            }
            return
        }

        // Ensure commands still work from main window/no target device by opening a neutral player window.
        let neutralWindowIdentifier = LocationPlayerWindowCoordinator.windowIdentifierRawValue(for: nil)
        LocationPlayerWindowCoordinator.openOrFocusWindow(for: nil, openWindow: openWindow)
        LocationPlayerMenuCommandCenter.shared.queue(command, targetWindowIdentifier: neutralWindowIdentifier)
    }
}
