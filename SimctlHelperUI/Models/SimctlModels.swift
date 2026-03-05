//
//  SimctlModels.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import Foundation

// MARK: - Root Response
struct SimctlListResponse: Codable {
    let devicetypes: [SimDeviceType]
    let runtimes: [SimRuntime]
    let devices: [String: [SimDevice]]
    let pairs: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case devicetypes, runtimes, devices, pairs
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devicetypes = try container.decode([SimDeviceType].self, forKey: .devicetypes)
        runtimes = try container.decode([SimRuntime].self, forKey: .runtimes)
        devices = try container.decode([String: [SimDevice]].self, forKey: .devices)
        pairs = try? container.decode([String: AnyCodable].self, forKey: .pairs)
    }
}

// MARK: - Device Type
struct SimDeviceType: Codable, Identifiable {
    let productFamily: String
    let bundlePath: String
    let maxRuntimeVersion: Int
    let maxRuntimeVersionString: String
    let identifier: String
    let modelIdentifier: String
    let minRuntimeVersionString: String
    let minRuntimeVersion: Int
    let name: String
    
    var id: String { identifier }
}

// MARK: - Runtime
struct SimRuntime: Codable, Identifiable {
    let isAvailable: Bool
    let version: String
    let isInternal: Bool
    let buildversion: String
    let supportedArchitectures: [String]
    let supportedDeviceTypes: [SimDeviceTypeReference]
    let identifier: String
    let platform: String
    let bundlePath: String
    let runtimeRoot: String
    let lastUsage: [String: String]?
    let name: String
    
    var id: String { identifier }
}

struct SimDeviceTypeReference: Codable {
    let bundlePath: String
    let name: String
    let identifier: String
    let productFamily: String
}

// MARK: - Device
struct SimDevice: Codable, Identifiable {
    let lastBootedAt: String?
    let dataPath: String
    let dataPathSize: Int
    let logPath: String
    let udid: String
    let isAvailable: Bool
    let logPathSize: Int?
    let deviceTypeIdentifier: String
    let state: DeviceState
    let name: String
    
    // Runtime identifier will be set when flattening devices
    var runtimeIdentifier: String?
    
    var id: String { udid }
    
    enum CodingKeys: String, CodingKey {
        case lastBootedAt, dataPath, dataPathSize, logPath, udid, isAvailable
        case logPathSize, deviceTypeIdentifier, state, name
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastBootedAt = try? container.decode(String.self, forKey: .lastBootedAt)
        dataPath = try container.decode(String.self, forKey: .dataPath)
        dataPathSize = try container.decode(Int.self, forKey: .dataPathSize)
        logPath = try container.decode(String.self, forKey: .logPath)
        udid = try container.decode(String.self, forKey: .udid)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        logPathSize = try? container.decode(Int.self, forKey: .logPathSize)
        deviceTypeIdentifier = try container.decode(String.self, forKey: .deviceTypeIdentifier)
        
        let stateString = try container.decode(String.self, forKey: .state)
        state = DeviceState(rawValue: stateString) ?? .shutdown
        
        name = try container.decode(String.self, forKey: .name)
        runtimeIdentifier = nil
    }
    
    // Helper computed properties
    var isBooted: Bool {
        state == .booted
    }
    
    var firmwareVersion: String {
        // Will be populated from runtime info
        runtimeIdentifier?.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " ") ?? L10n.t("Unknown")
    }
    
    var deviceTypeName: String {
        // Extract device type name from identifier
        deviceTypeIdentifier
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimDeviceType.", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
}

enum DeviceState: String, Codable {
    case booted = "Booted"
    case shutdown = "Shutdown"
    
    var displayName: String {
        switch self {
        case .booted:
            return L10n.t("Booted")
        case .shutdown:
            return L10n.t("Shutdown")
        }
    }
}

// MARK: - Helper for decoding Any
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded"))
        }
    }
}
