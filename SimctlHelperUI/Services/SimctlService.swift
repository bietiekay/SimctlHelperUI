//
//  SimctlService.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import Foundation
import Darwin

enum SimctlError: LocalizedError {
    case commandFailed(String)
    case invalidJSON
    case deviceNotFound
    case invalidDeviceName
    case refreshFailedAfterRetries(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .invalidJSON:
            return "Invalid JSON response"
        case .deviceNotFound:
            return "Device not found"
        case .invalidDeviceName:
            return "Invalid device name"
        case .refreshFailedAfterRetries(let message):
            return "Device cloned successfully, but failed to refresh device list: \(message). Please refresh manually."
        }
    }
}

protocol SimctlLocationControlling: AnyObject {
    func setLocation(udid: String, point: GeoPoint) async throws
    func clearLocation(udid: String) async throws
    func startRoute(udid: String, route: SavedRoute) async throws
    func pauseRoute(udid: String) throws
    func resumeRoute(udid: String) throws
    func stopRoute(udid: String) async
    func playbackState(udid: String) -> PlaybackState
    func deviceBootState(udid: String) async throws -> DeviceState
    func deviceName(udid: String) async throws -> String
}

// Thread-safe data collector for command execution
final class CommandDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var outputData = Data()
    nonisolated(unsafe) private var errorData = Data()
    nonisolated(unsafe) private var hasResumed = false

    nonisolated func appendOutput(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        outputData.append(data)
    }

    nonisolated func appendError(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        errorData.append(data)
    }

    nonisolated func finalize(remainingOutput: Data, remainingError: Data) -> (output: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        if !remainingOutput.isEmpty {
            outputData.append(remainingOutput)
        }
        if !remainingError.isEmpty {
            errorData.append(remainingError)
        }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        return (output: output, error: error)
    }

    nonisolated func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasResumed {
            return false
        }
        hasResumed = true
        return true
    }
}

private struct RouteSession {
    let process: Process
    let routeID: UUID
    let outputPipe: Pipe
    let errorPipe: Pipe
    let collector: CommandDataCollector
}

private final class RouteSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: RouteSession] = [:]
    private var states: [String: PlaybackState] = [:]
    private var stoppingUDIDs: Set<String> = []

    nonisolated func setSession(_ session: RouteSession, for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[udid] = session
    }

    nonisolated func session(for udid: String) -> RouteSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[udid]
    }

    nonisolated func removeSession(for udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: udid)
        return stoppingUDIDs.remove(udid) != nil
    }

    nonisolated func markStopping(_ udid: String) {
        lock.lock()
        defer { lock.unlock() }
        stoppingUDIDs.insert(udid)
    }

    nonisolated func setPlaybackState(_ state: PlaybackState, for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        states[udid] = state
    }

    nonisolated func playbackState(for udid: String) -> PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return states[udid] ?? .idle
    }

    nonisolated func routeID(for udid: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[udid] else {
            return nil
        }
        return session.routeID
    }

    nonisolated func clearState(for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: udid)
        stoppingUDIDs.remove(udid)
        sessions.removeValue(forKey: udid)
    }
}

class SimctlService: SimctlLocationControlling {
    static let shared = SimctlService()

    private let routeSessions = RouteSessionStore()

    private init() {}

    // MARK: - Command Execution

    private func executeCommand(_ arguments: [String]) async throws -> (output: String, error: String) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments

            // Configure environment
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = Pipe() // Prevent waiting for input

            // Read data asynchronously to prevent hanging
            let collector = CommandDataCollector()

            let resumeOnce: (Result<(output: String, error: String), Error>) -> Void = { result in
                guard collector.tryResume() else {
                    return
                }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    collector.appendOutput(data)
                } else {
                    handle.readabilityHandler = nil
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    collector.appendError(data)
                } else {
                    handle.readabilityHandler = nil
                }
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOutput = outputPipe.fileHandleForReading.availableData
                let remainingError = errorPipe.fileHandleForReading.availableData

                outputPipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()

                let (output, error) = collector.finalize(remainingOutput: remainingOutput, remainingError: remainingError)

                if process.terminationStatus != 0 {
                    resumeOnce(.failure(SimctlError.commandFailed(error.isEmpty ? output : error)))
                } else {
                    resumeOnce(.success((output: output, error: error)))
                }
            }

            do {
                try process.run()

                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                    if process.isRunning {
                        if collector.tryResume() {
                            process.terminate()
                            resumeOnce(.failure(SimctlError.commandFailed("Command timed out after 30 seconds")))
                        }
                    }
                }
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    private func createLongRunningProcess(arguments: [String], collector: CommandDataCollector) -> (process: Process, outputPipe: Pipe, errorPipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = Pipe()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.appendOutput(data)
            } else {
                handle.readabilityHandler = nil
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.appendError(data)
            } else {
                handle.readabilityHandler = nil
            }
        }

        return (process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    }

    // MARK: - Fetch Device List

    func fetchDeviceList() async throws -> SimctlListResponse {
        let result = try await executeCommand(["list", "-j"])

        guard let data = result.output.data(using: .utf8) else {
            throw SimctlError.invalidJSON
        }

        let decoder = JSONDecoder()
        return try decoder.decode(SimctlListResponse.self, from: data)
    }

    func deviceBootState(udid: String) async throws -> DeviceState {
        let response = try await fetchDeviceList()
        guard let device = findDevice(udid: udid, response: response) else {
            throw SimctlError.deviceNotFound
        }
        return device.state
    }

    func deviceName(udid: String) async throws -> String {
        let response = try await fetchDeviceList()
        guard let device = findDevice(udid: udid, response: response) else {
            throw SimctlError.deviceNotFound
        }
        return device.name
    }

    private func findDevice(udid: String, response: SimctlListResponse) -> SimDevice? {
        for devices in response.devices.values {
            if let match = devices.first(where: { $0.udid == udid }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Clone Device

    func cloneDevice(udid: String, name: String) async throws {
        guard !name.isEmpty else {
            throw SimctlError.invalidDeviceName
        }

        let invalidCharacters = CharacterSet(charactersIn: "\"\\")
        if name.rangeOfCharacter(from: invalidCharacters) != nil {
            throw SimctlError.invalidDeviceName
        }

        _ = try await executeCommand(["clone", udid, name])
    }

    // MARK: - Delete Device

    func deleteDevice(udid: String) async throws {
        _ = try await executeCommand(["delete", udid])
    }

    func deleteUnavailableDevices() async throws {
        _ = try await executeCommand(["delete", "unavailable"])
    }

    // MARK: - Boot Device

    func bootDevice(udid: String) async throws {
        _ = try await executeCommand(["boot", udid])
    }

    // MARK: - Shutdown Device

    func shutdownDevice(udid: String) async throws {
        _ = try await executeCommand(["shutdown", udid])
    }

    // MARK: - Location APIs

    func setLocation(udid: String, point: GeoPoint) async throws {
        try point.validate()
        _ = try await executeCommand(["location", udid, "set", LocationCommandBuilder.formatPoint(point)])
    }

    func clearLocation(udid: String) async throws {
        _ = try await executeCommand(["location", udid, "clear"])
    }

    func startRoute(udid: String, route: SavedRoute) async throws {
        try route.validate()

        // Stop any existing run for this simulator before starting a new one.
        await stopRoute(udid: udid)

        let collector = CommandDataCollector()
        let arguments = try LocationCommandBuilder.startArguments(udid: udid, route: route)
        let runnable = createLongRunningProcess(arguments: arguments, collector: collector)

        let session = RouteSession(
            process: runnable.process,
            routeID: route.id,
            outputPipe: runnable.outputPipe,
            errorPipe: runnable.errorPipe,
            collector: collector
        )

        routeSessions.setSession(session, for: udid)
        routeSessions.setPlaybackState(.running(routeID: route.id), for: udid)

        runnable.process.terminationHandler = { [weak self] process in
            guard let self else { return }

            runnable.outputPipe.fileHandleForReading.readabilityHandler = nil
            runnable.errorPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOutput = runnable.outputPipe.fileHandleForReading.availableData
            let remainingError = runnable.errorPipe.fileHandleForReading.availableData

            runnable.outputPipe.fileHandleForReading.closeFile()
            runnable.errorPipe.fileHandleForReading.closeFile()

            let (output, error) = collector.finalize(remainingOutput: remainingOutput, remainingError: remainingError)
            let combinedMessage = error.isEmpty ? output : error
            let wasStopping = self.routeSessions.removeSession(for: udid)

            if wasStopping {
                self.routeSessions.setPlaybackState(.idle, for: udid)
                return
            }

            if process.terminationStatus == 0 {
                self.routeSessions.setPlaybackState(.finished, for: udid)
            } else {
                let message = combinedMessage.isEmpty ? "Route process terminated with status \(process.terminationStatus)." : combinedMessage
                self.routeSessions.setPlaybackState(.failed(message: message), for: udid)
            }
        }

        do {
            try runnable.process.run()
        } catch {
            routeSessions.clearState(for: udid)
            throw error
        }
    }

    func pauseRoute(udid: String) throws {
        guard let session = routeSessions.session(for: udid) else {
            return
        }

        guard session.process.isRunning else {
            routeSessions.setPlaybackState(.finished, for: udid)
            return
        }

        let result = kill(session.process.processIdentifier, SIGSTOP)
        guard result == 0 else {
            throw SimctlError.commandFailed("Failed to pause route session.")
        }

        routeSessions.setPlaybackState(.paused(routeID: session.routeID), for: udid)
    }

    func resumeRoute(udid: String) throws {
        guard let session = routeSessions.session(for: udid) else {
            return
        }

        guard session.process.isRunning else {
            routeSessions.setPlaybackState(.finished, for: udid)
            return
        }

        let result = kill(session.process.processIdentifier, SIGCONT)
        guard result == 0 else {
            throw SimctlError.commandFailed("Failed to resume route session.")
        }

        routeSessions.setPlaybackState(.running(routeID: session.routeID), for: udid)
    }

    func stopRoute(udid: String) async {
        if let session = routeSessions.session(for: udid) {
            routeSessions.markStopping(udid)
            routeSessions.setPlaybackState(.idle, for: udid)

            if session.process.isRunning {
                session.process.terminate()

                for _ in 0..<10 {
                    if !session.process.isRunning {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                if session.process.isRunning {
                    _ = kill(session.process.processIdentifier, SIGKILL)
                }
            }
        } else {
            routeSessions.setPlaybackState(.idle, for: udid)
        }

        do {
            try await clearLocation(udid: udid)
        } catch {
            routeSessions.setPlaybackState(.failed(message: error.localizedDescription), for: udid)
        }
    }

    func playbackState(udid: String) -> PlaybackState {
        routeSessions.playbackState(for: udid)
    }
}
