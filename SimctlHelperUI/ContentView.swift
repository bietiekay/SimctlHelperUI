//
//  ContentView.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DeviceListViewModel()
    @State private var showDeleteUnavailableConfirmation = false
    @State private var isDeletingUnavailable = false
    
    var body: some View {
        HSplitView {
            deviceListView
            actionsPanel
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Delete Unavailable Simulators", isPresented: $showDeleteUnavailableConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                deleteUnavailableDevices()
            }
        } message: {
            Text("This removes all unavailable simulators from the current list.")
        }
    }
    
    private var deviceListView: some View {
        VStack(spacing: 0) {
            toolbarView
            deviceTable
        }
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var toolbarView: some View {
        HStack {
            Button(action: {
                Task {
                    await viewModel.refreshDevices()
                }
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading || isDeletingUnavailable)
            
            if viewModel.hasUnavailableDevices {
                Button(role: .destructive, action: {
                    showDeleteUnavailableConfirmation = true
                }) {
                    Label("Delete Unavailable", systemImage: "trash.slash")
                }
                .disabled(viewModel.isLoading || isDeletingUnavailable)
            }
            
            Spacer()
            
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    @ViewBuilder
    private var deviceTable: some View {
        if viewModel.devices.isEmpty && !viewModel.isLoading {
            emptyStateView
        } else {
            tableContent
        }
    }
    
    private var emptyStateView: some View {
        VStack {
            Text("No devices found")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var tableContent: some View {
        let selectionBinding = Binding<SimDevice.ID?>(
            get: { viewModel.selectedDevice?.id },
            set: { id in
                if let id = id {
                    viewModel.selectedDevice = viewModel.devices.first { $0.id == id }
                    // Refresh devices list when selection changes
                    Task {
                        await viewModel.refreshDevices()
                    }
                } else {
                    viewModel.selectedDevice = nil
                }
            }
        )
        
        return Table(viewModel.devices, selection: selectionBinding) {
            TableColumn("Name") { device in
                DeviceNameCell(device: device)
            }
            .width(min: 200, ideal: 250)
            TableColumn("State") { device in
                DeviceStateCell(device: device)
            }
            TableColumn("Availability") { device in
                DeviceAvailabilityCell(device: device)
            }
            TableColumn("Device Type") { device in
                Text(viewModel.deviceTypeName(for: device))
            }
            TableColumn("Runtime") { device in
                Text(viewModel.runtimeVersion(for: device))
            }
        }
    }
    
    private var actionsPanel: some View {
        DeviceActionsView(viewModel: viewModel)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
    }
    
    private func deleteUnavailableDevices() {
        isDeletingUnavailable = true
        viewModel.errorMessage = nil
        
        Task {
            do {
                try await viewModel.deleteUnavailableDevices()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
            isDeletingUnavailable = false
        }
    }
}

// MARK: - Helper Views

struct DeviceNameCell: View {
    let device: SimDevice
    
    var body: some View {
        HStack {
            Circle()
                .fill(device.isBooted ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(device.name)
        }
    }
}

struct DeviceStateCell: View {
    let device: SimDevice
    
    var body: some View {
        HStack {
            Circle()
                .fill(device.isBooted ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(device.state.displayName)
        }
    }
}

struct DeviceAvailabilityCell: View {
    let device: SimDevice
    
    var body: some View {
        Text(device.isAvailable ? "Available" : "Unavailable")
            .foregroundColor(device.isAvailable ? .primary : .secondary)
    }
}

#Preview {
    ContentView()
}
