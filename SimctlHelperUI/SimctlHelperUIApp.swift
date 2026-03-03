//
//  SimctlHelperUIApp.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI
import AppKit

@main
struct SimctlHelperUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(
                    WindowObserverView { window in
                        LocationPlayerWindowCoordinator.assignMainWindowIdentifier(to: window)
                    }
                )
        }

        WindowGroup("Location Player", id: "location-player", for: String.self) { udid in
            LocationPlayerSceneView(initialUDID: udid.wrappedValue)
        }
        .defaultSize(width: 980, height: 640)
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
