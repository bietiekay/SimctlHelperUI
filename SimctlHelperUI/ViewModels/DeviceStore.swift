import Foundation
import Combine

enum DeviceFilter: String, CaseIterable, Identifiable {
    case all
    case booted
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.t("All")
        case .booted:
            return L10n.t("Booted")
        case .unavailable:
            return L10n.t("Unavailable")
        }
    }
}

enum DeviceSortKey: String, CaseIterable, Identifiable {
    case name
    case state
    case availability
    case deviceType
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return L10n.t("Name")
        case .state:
            return L10n.t("State")
        case .availability:
            return L10n.t("Availability")
        case .deviceType:
            return L10n.t("Device Type")
        case .runtime:
            return L10n.t("Runtime")
        }
    }
}

enum DeviceSortDirection {
    case ascending
    case descending

    var toggled: DeviceSortDirection {
        switch self {
        case .ascending:
            return .descending
        case .descending:
            return .ascending
        }
    }
}

struct DeviceRecord: Identifiable {
    let device: SimDevice
    let deviceTypeName: String
    let runtimeName: String

    var id: String { device.udid }
    var udid: String { device.udid }
    var name: String { device.name }
    var state: DeviceState { device.state }
    var availabilityText: String { device.isAvailable ? L10n.t("Available") : L10n.t("Unavailable") }
    var isAvailable: Bool { device.isAvailable }
    var isBooted: Bool { device.isBooted }
}

@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published private(set) var devices: [DeviceRecord] = []
    @Published private(set) var isLoading = false
    @Published var feedback: FeedbackMessage?
    @Published var sortKey: DeviceSortKey = .name
    @Published var sortDirection: DeviceSortDirection = .ascending

    var hasUnavailableDevices: Bool {
        devices.contains { !$0.isAvailable }
    }

    private let service: SimctlService
    private var runtimes: [String: SimRuntime] = [:]
    private var deviceTypes: [String: SimDeviceType] = [:]
    private var isRefreshing = false

    init(service: SimctlService, autoload: Bool = true) {
        self.service = service

        if autoload {
            Task {
                await refreshDevices()
            }
        }
    }

    convenience init(autoload: Bool = true) {
        self.init(service: .shared, autoload: autoload)
    }

    func device(for udid: String) -> DeviceRecord? {
        devices.first { $0.udid == udid }
    }

    func refreshDevices(showLoadingIndicator: Bool = true, preserveFeedback: Bool = false) async {
        await waitForOngoingRefresh()
        isRefreshing = true

        if showLoadingIndicator {
            isLoading = true
        }
        if !preserveFeedback {
            feedback = nil
        }

        defer {
            isRefreshing = false
            if showLoadingIndicator {
                isLoading = false
            }
        }

        do {
            let response = try await service.fetchDeviceList()
            runtimes = Dictionary(uniqueKeysWithValues: response.runtimes.map { ($0.identifier, $0) })
            deviceTypes = Dictionary(uniqueKeysWithValues: response.devicetypes.map { ($0.identifier, $0) })

            var flattenedRecords: [DeviceRecord] = []
            for (runtimeIdentifier, deviceList) in response.devices {
                for var device in deviceList {
                    device.runtimeIdentifier = runtimeIdentifier
                    flattenedRecords.append(
                        DeviceRecord(
                            device: device,
                            deviceTypeName: deviceTypes[device.deviceTypeIdentifier]?.name ?? device.deviceTypeName,
                            runtimeName: runtimes[runtimeIdentifier]?.name ?? L10n.t("Unknown")
                        )
                    )
                }
            }

            devices = flattenedRecords
            applySorting()
        } catch {
            if devices.isEmpty || !preserveFeedback {
                feedback = FeedbackMessage(level: .error, text: error.localizedDescription)
            }
        }
    }

    func refreshDevicesInBackground() async {
        await refreshDevices(showLoadingIndicator: false, preserveFeedback: true)
    }

    func setSortKey(_ newKey: DeviceSortKey) {
        if sortKey == newKey {
            sortDirection = sortDirection.toggled
        } else {
            sortKey = newKey
            sortDirection = .ascending
        }
        applySorting()
    }

    func cloneDevice(udid: String, name: String) async throws {
        try await service.cloneDevice(udid: udid, name: name)

        try? await Task.sleep(nanoseconds: 500_000_000)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await refreshDevicesThrowing()
                feedback = FeedbackMessage(level: .success, text: L10n.t("Simulator cloned successfully."))
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    let delay = UInt64(500_000_000 * UInt64(1 << (attempt - 1)))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw SimctlError.refreshFailedAfterRetries(lastError?.localizedDescription ?? L10n.t("Unknown error"))
    }

    func deleteDevice(udid: String) async throws {
        try await service.deleteDevice(udid: udid)
        await refreshDevices()
        feedback = FeedbackMessage(level: .success, text: L10n.t("Simulator deleted."))
    }

    func bootDevice(udid: String) async throws {
        try await service.bootDevice(udid: udid)
        await refreshDevices()
        feedback = FeedbackMessage(level: .success, text: L10n.t("Simulator boot command sent."))
    }

    func shutdownDevice(udid: String) async throws {
        try await service.shutdownDevice(udid: udid)
        await refreshDevices()
        feedback = FeedbackMessage(level: .success, text: L10n.t("Simulator shutdown command sent."))
    }

    func deleteUnavailableDevices() async throws {
        try await service.deleteUnavailableDevices()
        await refreshDevices()
        feedback = FeedbackMessage(level: .success, text: L10n.t("Unavailable simulators deleted."))
    }

    func clearFeedback() {
        feedback = nil
    }

    private func refreshDevicesThrowing() async throws {
        await waitForOngoingRefresh()
        isRefreshing = true
        defer { isRefreshing = false }

        let response = try await service.fetchDeviceList()
        runtimes = Dictionary(uniqueKeysWithValues: response.runtimes.map { ($0.identifier, $0) })
        deviceTypes = Dictionary(uniqueKeysWithValues: response.devicetypes.map { ($0.identifier, $0) })

        var flattenedRecords: [DeviceRecord] = []
        for (runtimeIdentifier, deviceList) in response.devices {
            for var device in deviceList {
                device.runtimeIdentifier = runtimeIdentifier
                flattenedRecords.append(
                    DeviceRecord(
                        device: device,
                        deviceTypeName: deviceTypes[device.deviceTypeIdentifier]?.name ?? device.deviceTypeName,
                        runtimeName: runtimes[runtimeIdentifier]?.name ?? L10n.t("Unknown")
                    )
                )
            }
        }

        devices = flattenedRecords
        applySorting()
    }

    private func waitForOngoingRefresh() async {
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func applySorting() {
        devices.sort { lhs, rhs in
            let comparison: ComparisonResult

            switch sortKey {
            case .name:
                comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .state:
                comparison = lhs.state.rawValue.localizedCaseInsensitiveCompare(rhs.state.rawValue)
            case .availability:
                comparison = lhs.isAvailable == rhs.isAvailable
                    ? .orderedSame
                    : (lhs.isAvailable ? .orderedAscending : .orderedDescending)
            case .deviceType:
                comparison = lhs.deviceTypeName.localizedCaseInsensitiveCompare(rhs.deviceTypeName)
            case .runtime:
                comparison = lhs.runtimeName.localizedCaseInsensitiveCompare(rhs.runtimeName)
            }

            switch comparison {
            case .orderedAscending:
                return sortDirection == .ascending
            case .orderedDescending:
                return sortDirection == .descending
            case .orderedSame:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
