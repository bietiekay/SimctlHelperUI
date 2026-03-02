//
//  SimctlHelperUIApp.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI

@main
struct SimctlHelperUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        WindowGroup("Location Player", id: "location-player", for: String.self) { udid in
            if let udid = udid.wrappedValue {
                LocationPlayerSceneView(udid: udid)
            } else {
                Text("No simulator selected.")
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
        .defaultSize(width: 980, height: 640)
    }
}

private struct LocationPlayerSceneView: View {
    @StateObject private var viewModel: LocationPlayerViewModel

    init(udid: String) {
        _viewModel = StateObject(wrappedValue: LocationPlayerViewModel(udid: udid))
    }

    var body: some View {
        LocationPlayerView(viewModel: viewModel)
    }
}
