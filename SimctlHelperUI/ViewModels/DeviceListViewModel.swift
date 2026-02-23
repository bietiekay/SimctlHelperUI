//
//  DeviceListViewModel.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import Foundation
import SwiftUI
import Combine

enum SortKey: String, CaseIterable {
    case name = "Name"
    case state = "State"
    case availability = "Availability"
    case deviceType = "Device Type"
    case runtimeVersion = "Runtime Version"
}

enum SortOrder {
    case ascending
    case descending
    
    var toggle: SortOrder {
        switch self {
        case .ascending: return .descending
        case .descending: return .ascending
        }
    }
}

@MainActor
class DeviceListViewModel: ObservableObject {
    @Published var devices: [SimDevice] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var sortKey: SortKey = .name
    @Published var sortOrder: SortOrder = .ascending
    @Published var selectedDevice: SimDevice?
    
    var hasUnavailableDevices: Bool {
        devices.contains { !$0.isAvailable }
    }
    
    private let service = SimctlService.shared
    private var runtimes: [String: SimRuntime] = [:]
    private var deviceTypes: [String: SimDeviceType] = [:]
    
    init() {
        Task {
            await loadDevices()
        }
    }
    
    // MARK: - Load Devices
    
    func loadDevices() async {
        isLoading = true
        errorMessage = nil
        
        // Preserve selected device UDID before refresh
        let selectedUdid = selectedDevice?.udid
        
        do {
            let response = try await service.fetchDeviceList()
            
            // Store runtimes and device types for lookup
            runtimes = Dictionary(uniqueKeysWithValues: response.runtimes.map { ($0.identifier, $0) })
            deviceTypes = Dictionary(uniqueKeysWithValues: response.devicetypes.map { ($0.identifier, $0) })
            
            // Flatten devices and enrich with runtime info
            var flattenedDevices: [SimDevice] = []
            for (runtimeId, deviceList) in response.devices {
                for var device in deviceList {
                    device.runtimeIdentifier = runtimeId
                    flattenedDevices.append(device)
                }
            }
            
            devices = flattenedDevices
            applySorting()
            
            // Restore selection after refresh if device still exists
            if let selectedUdid = selectedUdid {
                selectedDevice = devices.first { $0.udid == selectedUdid }
            }
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    func refreshDevices() async {
        await loadDevices()
    }
    
    private func refreshDevicesThrowing() async throws {
        let response = try await service.fetchDeviceList()
        
        // Store runtimes and device types for lookup
        runtimes = Dictionary(uniqueKeysWithValues: response.runtimes.map { ($0.identifier, $0) })
        deviceTypes = Dictionary(uniqueKeysWithValues: response.devicetypes.map { ($0.identifier, $0) })
        
        // Preserve selected device UDID before refresh
        let selectedUdid = selectedDevice?.udid
        
        // Flatten devices and enrich with runtime info
        var flattenedDevices: [SimDevice] = []
        for (runtimeId, deviceList) in response.devices {
            for var device in deviceList {
                device.runtimeIdentifier = runtimeId
                flattenedDevices.append(device)
            }
        }
        
        devices = flattenedDevices
        applySorting()
        
        // Restore selection after refresh if device still exists
        if let selectedUdid = selectedUdid {
            selectedDevice = devices.first { $0.udid == selectedUdid }
        }
    }
    
    // MARK: - Sorting
    
    func setSortKey(_ key: SortKey) {
        if sortKey == key {
            sortOrder = sortOrder.toggle
        } else {
            sortKey = key
            sortOrder = .ascending
        }
        applySorting()
    }
    
    private func applySorting() {
        devices.sort { device1, device2 in
            let comparison: ComparisonResult
            
            switch sortKey {
            case .name:
                comparison = device1.name.compare(device2.name)
            case .state:
                comparison = device1.state.rawValue.compare(device2.state.rawValue)
            case .availability:
                comparison = device1.isAvailable == device2.isAvailable ? .orderedSame :
                             device1.isAvailable ? .orderedAscending : .orderedDescending
            case .deviceType:
                comparison = device1.deviceTypeName.compare(device2.deviceTypeName)
            case .runtimeVersion:
                let runtime1 = runtimeVersion(for: device1)
                let runtime2 = runtimeVersion(for: device2)
                comparison = runtime1.compare(runtime2)
            }
            
            if sortOrder == .ascending {
                return comparison == .orderedAscending
            } else {
                return comparison == .orderedDescending
            }
        }
    }
    
    // MARK: - Device Info Helpers
    
    func runtimeVersion(for device: SimDevice) -> String {
        guard let runtimeId = device.runtimeIdentifier,
              let runtime = runtimes[runtimeId] else {
            return "Unknown"
        }
        return runtime.name
    }
    
    func deviceTypeName(for device: SimDevice) -> String {
        if let deviceType = deviceTypes[device.deviceTypeIdentifier] {
            return deviceType.name
        }
        return device.deviceTypeName
    }
    
    // MARK: - Actions
    
    func cloneDevice(udid: String, name: String) async throws {
        try await service.cloneDevice(udid: udid, name: name)
        
        // Wait a bit for simctl to finish writing device data before refreshing
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Retry refresh up to 3 times with exponential backoff
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await refreshDevicesThrowing()
                return // Success - refresh completed
            } catch {
                lastError = error
                
                if attempt < 3 {
                    // Exponential backoff: 0.5s, 1s, 2s
                    let delay = UInt64(500_000_000 * UInt64(1 << (attempt - 1)))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        
        // If all retries failed, throw an error indicating clone succeeded but refresh failed
        throw SimctlError.refreshFailedAfterRetries(lastError?.localizedDescription ?? "Unknown error")
    }
    
    func deleteDevice(udid: String) async throws {
        try await service.deleteDevice(udid: udid)
        if selectedDevice?.udid == udid {
            selectedDevice = nil
        }
        await refreshDevices()
    }
    
    func bootDevice(udid: String) async throws {
        try await service.bootDevice(udid: udid)
        await refreshDevices()
    }
    
    func shutdownDevice(udid: String) async throws {
        try await service.shutdownDevice(udid: udid)
        await refreshDevices()
    }
    
    func deleteUnavailableDevices() async throws {
        try await service.deleteUnavailableDevices()
        await refreshDevices()
    }
}
