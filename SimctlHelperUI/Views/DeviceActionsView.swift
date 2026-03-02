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
            VStack(alignment: .leading, spacing: 16) {
                if let device = viewModel.selectedDevice {
                    // Device Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Details")
                            .font(.headline)
                        
                        InfoRow(label: "Name", value: device.name)
                        InfoRow(label: "State", value: device.state.displayName)
                        InfoRow(label: "Availability", value: device.isAvailable ? "Available" : "Unavailable")
                        InfoRow(label: "Device Type", value: viewModel.deviceTypeName(for: device))
                        InfoRow(label: "Runtime", value: viewModel.runtimeVersion(for: device))
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
                            Label("Clone Device", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)
                        
                        // Boot/Shutdown Button
                        Button(action: {
                            toggleBootState()
                        }) {
                            Label(
                                device.isBooted ? "Shutdown" : "Boot",
                                systemImage: device.isBooted ? "power" : "power.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)

                        if device.isBooted {
                            Button(action: {
                                openWindow(id: "location-player", value: device.udid)
                            }) {
                                Label("Location Player", systemImage: "location")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(isPerformingAction)
                        }
                        
                        // Delete Button
                        Button(role: .destructive, action: {
                            showDeleteConfirmation = true
                        }) {
                            Label("Delete Device", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isPerformingAction)
                    }
                } else {
                    VStack {
                        Text("No device selected")
                            .foregroundColor(.secondary)
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
        .alert("Delete Device", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteDevice()
            }
        } message: {
            if let device = viewModel.selectedDevice {
                Text("Are you sure you want to delete \"\(device.name)\"? This action cannot be undone.")
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
