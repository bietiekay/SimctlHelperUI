//
//  DeviceActionsView.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI

struct DeviceActionsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: DeviceListViewModel
    @State private var showCloneDialog = false
    @State private var showDeleteConfirmation = false
    @State private var isPerformingAction = false
    @State private var actionError: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let device = viewModel.selectedDevice {
                    // Device Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("Device Details"))
                            .font(.headline)
                        
                        InfoRow(label: L10n.t("Name"), value: device.name)
                        InfoRow(label: L10n.t("State"), value: device.state.displayName)
                        InfoRow(label: L10n.t("Availability"), value: device.isAvailable ? L10n.t("Available") : L10n.t("Unavailable"))
                        InfoRow(label: L10n.t("Device Type"), value: viewModel.deviceTypeName(for: device))
                        InfoRow(label: L10n.t("Runtime"), value: viewModel.runtimeVersion(for: device))
                        InfoRow(label: "UDID", value: device.udid)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    // Actions
                    VStack(spacing: 12) {
                        if let actionError = actionError {
                            Text(actionError)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        
                        // Clone Button
                        Button(action: {
                            showCloneDialog = true
                        }) {
                            Label(L10n.t("Clone Device"), systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)
                        
                        // Boot/Shutdown Button
                        Button(action: {
                            toggleBootState()
                        }) {
                            Label(
                                device.isBooted ? L10n.t("Shutdown") : L10n.t("Boot"),
                                systemImage: device.isBooted ? "power" : "power.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)

                        Button(action: {
                            openLocationPlayerWindow(for: device.udid)
                        }) {
                            Label(L10n.t("Location Player"), systemImage: "location")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)
                        
                        // Delete Button
                        Button(role: .destructive, action: {
                            showDeleteConfirmation = true
                        }) {
                            Label(L10n.t("Delete Device"), systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text(L10n.t("No device selected"))
                            .foregroundColor(.secondary)

                        Button(action: {
                            openLocationPlayerWindow(for: nil)
                        }) {
                            Label(L10n.t("Open Location Player"), systemImage: "location")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showCloneDialog) {
            if let device = viewModel.selectedDevice {
                CloneDeviceView(
                    isPresented: $showCloneDialog,
                    deviceName: device.name
                ) { newName in
                    try await viewModel.cloneDevice(udid: device.udid, name: newName)
                }
            }
        }
        .alert(L10n.t("Delete Device"), isPresented: $showDeleteConfirmation) {
            Button(L10n.t("Cancel"), role: .cancel) {}
            Button(L10n.t("Delete"), role: .destructive) {
                deleteDevice()
            }
        } message: {
            if let device = viewModel.selectedDevice {
                Text(L10n.f("Are you sure you want to delete \"%@\"? This action cannot be undone.", device.name))
            }
        }
    }
    
    private func toggleBootState() {
        guard let device = viewModel.selectedDevice else { return }
        
        isPerformingAction = true
        actionError = nil
        
        Task {
            do {
                if device.isBooted {
                    try await viewModel.shutdownDevice(udid: device.udid)
                } else {
                    try await viewModel.bootDevice(udid: device.udid)
                }
            } catch {
                actionError = error.localizedDescription
            }
            isPerformingAction = false
        }
    }
    
    private func deleteDevice() {
        guard let device = viewModel.selectedDevice else { return }
        
        isPerformingAction = true
        actionError = nil
        
        Task {
            do {
                try await viewModel.deleteDevice(udid: device.udid)
            } catch {
                actionError = error.localizedDescription
            }
            isPerformingAction = false
        }
    }

    @MainActor
    private func openLocationPlayerWindow(for udid: String?) {
        LocationPlayerWindowCoordinator.openOrFocusWindow(for: udid, openWindow: openWindow)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
