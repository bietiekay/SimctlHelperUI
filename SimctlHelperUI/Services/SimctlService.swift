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
            return L10n.f("Command failed: %@", message)
        case .invalidJSON:
            return L10n.t("Invalid JSON response")
        case .deviceNotFound:
            return L10n.t("Device not found")
        case .invalidDeviceName:
            return L10n.t("Invalid device name")
        case .refreshFailedAfterRetries(let message):
            return L10n.f(
                "Device cloned successfully, but failed to refresh device list: %@. Please refresh manually.",
                message
            )
        }
    }
}

protocol SimctlLocationControlling: AnyObject {
    func fetchDeviceList() async throws -> SimctlListResponse
    func bootDevice(udid: String) async throws
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
    nonisolated(unsafe) private var sessions: [String: RouteSession] = [:]
    nonisolated(unsafe) private var states: [String: PlaybackState] = [:]
    nonisolated(unsafe) private var activeRouteIDs: [String: UUID] = [:]
    nonisolated(unsafe) private var stoppingUDIDs: Set<String> = []

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

    nonisolated func removeSession(for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: udid)
    }

    nonisolated func markStopping(_ udid: String) {
        lock.lock()
        defer { lock.unlock() }
        stoppingUDIDs.insert(udid)
    }

    nonisolated func consumeStopping(_ udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppingUDIDs.remove(udid) != nil
    }

    nonisolated func isStopping(_ udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppingUDIDs.contains(udid)
    }

    nonisolated func setPlaybackState(_ state: PlaybackState, for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        states[udid] = state
        switch state {
        case .running(let routeID), .paused(let routeID):
            activeRouteIDs[udid] = routeID
        case .idle:
            activeRouteIDs.removeValue(forKey: udid)
        case .finished, .failed:
            break
        }
    }

    nonisolated func playbackState(for udid: String) -> PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return states[udid] ?? .idle
    }

    nonisolated func routeID(for udid: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[udid] {
            return session.routeID
        }
        return activeRouteIDs[udid]
    }

    nonisolated func clearState(for udid: String) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: udid)
        activeRouteIDs.removeValue(forKey: udid)
        stoppingUDIDs.remove(udid)
        sessions.removeValue(forKey: udid)
    }
}

class SimctlService: SimctlLocationControlling {
    static let shared = SimctlService()

    private let routeSessions = RouteSessionStore()

    private init() {}

    nonisolated private func logDebug(_ message: String) {
        RouteDebugLogStore.shared.log("SimctlService: \(message)")
    }

    nonisolated private func summarize(_ value: String, limit: Int = 280) -> String {
        guard !value.isEmpty else { return "<empty>" }
        let singleLine = value.replacingOccurrences(of: "\n", with: "\\n")
        if singleLine.count <= limit {
            return singleLine
        }
        return "\(singleLine.prefix(limit))..."
    }

    // MARK: - Command Execution

    private func executeCommand(
        _ arguments: [String],
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async throws -> (output: String, error: String) {
        let commandLine = "xcrun simctl \(arguments.joined(separator: " "))"
        logDebug("executeCommand start: \(commandLine), timeout=\(Double(timeoutNanoseconds) / 1_000_000_000)s")

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
                self.logDebug(
                    """
                    executeCommand end: \(commandLine), status=\(process.terminationStatus), \
                    output=\(self.summarize(output)), error=\(self.summarize(error))
                    """
                )

                if process.terminationStatus != 0 {
                    resumeOnce(.failure(SimctlError.commandFailed(error.isEmpty ? output : error)))
                } else {
                    resumeOnce(.success((output: output, error: error)))
                }
            }

            do {
                try process.run()
                self.logDebug("executeCommand launched: \(commandLine), pid=\(process.processIdentifier)")

                Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    if process.isRunning {
                        self.logDebug("executeCommand timeout hit: \(commandLine), pid=\(process.processIdentifier)")
                        process.terminate()
                        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
                        resumeOnce(.failure(SimctlError.commandFailed("Command timed out after \(timeoutSeconds) seconds")))
                    }
                }
            } catch {
                self.logDebug("executeCommand failed to launch: \(commandLine), error=\(error.localizedDescription)")
                resumeOnce(.failure(error))
            }
        }
    }

    private func createLongRunningProcess(
        arguments: [String],
        collector: CommandDataCollector,
        standardInputPipe: Pipe? = nil
    ) -> (process: Process, outputPipe: Pipe, errorPipe: Pipe, inputPipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = standardInputPipe ?? Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

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

        return (process: process, outputPipe: outputPipe, errorPipe: errorPipe, inputPipe: inputPipe)
    }

    nonisolated private func runningExternalLocationStartPIDs(for udid: String) -> [pid_t] {
        logDebug("Scanning external route-start processes for udid=\(udid)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,command="]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logDebug("Failed to run ps -ax for udid=\(udid): \(error.localizedDescription)")
            return []
        }

        // Drain output before waiting to avoid pipe backpressure deadlocks on busy systems.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        outputPipe.fileHandleForReading.closeFile()

        guard process.terminationStatus == 0 else {
            logDebug("ps -ax returned non-zero status=\(process.terminationStatus) while scanning udid=\(udid)")
            return []
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        let token = "simctl location \(udid) start"
        var pids: [pid_t] = []

        for line in output.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            let parts = trimmedLine.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            guard let pid = Int32(parts[0]) else { continue }

            let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if command.localizedCaseInsensitiveContains(token) && pid != getpid() {
                pids.append(pid)
            }
        }

        logDebug("Found \(pids.count) external route-start processes for udid=\(udid): \(pids.map(String.init).joined(separator: ","))")
        return pids
    }

    nonisolated private func commandLine(for pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logDebug("Failed to inspect pid=\(pid): \(error.localizedDescription)")
            return nil
        }

        // Read first, then wait to avoid potential deadlock when stdout pipe fills.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        outputPipe.fileHandleForReading.closeFile()

        guard process.terminationStatus == 0 else {
            logDebug("ps -p failed for pid=\(pid), status=\(process.terminationStatus)")
            return nil
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let command = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    nonisolated private func terminateExternalLocationStartProcesses(for udid: String) {
        let token = "simctl location \(udid) start"
        let pids = runningExternalLocationStartPIDs(for: udid)
        guard !pids.isEmpty else {
            logDebug("No external route-start processes to terminate for udid=\(udid)")
            return
        }

        logDebug("Terminating \(pids.count) external route-start process(es) for udid=\(udid)")

        for pid in pids {
            _ = kill(pid, SIGTERM)
        }

        usleep(200_000)

        for pid in pids where kill(pid, 0) == 0 {
            guard let command = commandLine(for: pid),
                  command.localizedCaseInsensitiveContains(token),
                  pid != getpid() else {
                continue
            }
            _ = kill(pid, SIGKILL)
            logDebug("SIGKILL sent to stubborn external process pid=\(pid) for udid=\(udid)")
        }
    }

    nonisolated private func signalExternalLocationStartProcesses(
        for udid: String,
        signal: Int32,
        signalName: String
    ) -> Bool {
        let pids = runningExternalLocationStartPIDs(for: udid)
        guard !pids.isEmpty else {
            logDebug("No external route-start processes to signal (\(signalName)) for udid=\(udid)")
            return false
        }

        var successfulSignals = 0
        for pid in pids {
            if kill(pid, signal) == 0 {
                successfulSignals += 1
            } else {
                logDebug("Failed to send \(signalName) to pid=\(pid) for udid=\(udid)")
            }
        }

        if successfulSignals > 0 {
            logDebug("Sent \(signalName) to \(successfulSignals)/\(pids.count) external route-start process(es) for udid=\(udid)")
            return true
        }
        return false
    }

    private func terminateExternalLocationStartProcessesAsync(for udid: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                terminateExternalLocationStartProcesses(for: udid)
                continuation.resume()
            }
        }
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
        _ = try await executeCommand(
            ["location", udid, "clear"],
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func startRoute(udid: String, route: SavedRoute) async throws {
        try route.validate()
        logDebug(
            """
            startRoute requested: udid=\(udid), routeID=\(route.id.uuidString), \
            waypoints=\(route.waypoints.count), speed=\(route.speedMetersPerSecond), mode=\(route.updateMode)
            """
        )

        // Stop any existing run for this simulator before starting a new one.
        // Route startup should not block on `location clear`; terminate any active route process and continue.
        await stopRoute(udid: udid, shouldClearLocation: false)

        let segments: [[GeoPoint]]
        if route.waypoints.count > LocationCommandBuilder.maxWaypointsPerSegment {
            // Newer simctl variants may return immediately after parsing and treat repeated `start`
            // calls like replacements. For large routes, send one full payload via STDIN instead.
            segments = [route.waypoints]
            logDebug(
                """
                startRoute using single payload mode for large route: udid=\(udid), \
                totalWaypoints=\(route.waypoints.count), segmentCount=1 (chunking disabled)
                """
            )
        } else {
            segments = try LocationCommandBuilder.waypointSegments(route: route)
            logDebug("startRoute segmented route for udid=\(udid): segmentCount=\(segments.count)")
        }

        routeSessions.setPlaybackState(.running(routeID: route.id), for: udid)
        do {
            try startRouteSegment(
                udid: udid,
                route: route,
                segments: segments,
                segmentIndex: 0
            )
        } catch {
            routeSessions.clearState(for: udid)
            logDebug("startRoute failed for udid=\(udid), routeID=\(route.id.uuidString): \(error.localizedDescription)")
            throw error
        }
    }

    private func startRouteSegment(
        udid: String,
        route: SavedRoute,
        segments: [[GeoPoint]],
        segmentIndex: Int
    ) throws {
        guard !routeSessions.isStopping(udid) else {
            _ = routeSessions.consumeStopping(udid)
            routeSessions.setPlaybackState(.idle, for: udid)
            logDebug("Skipping segment start because stop was requested for udid=\(udid)")
            return
        }

        guard segmentIndex < segments.count else {
            routeSessions.setPlaybackState(.finished, for: udid)
            logDebug("Route finished for udid=\(udid), routeID=\(route.id.uuidString)")
            return
        }

        let segmentRoute = SavedRoute(
            id: route.id,
            name: route.name,
            waypoints: segments[segmentIndex],
            speedMetersPerSecond: route.speedMetersPerSecond,
            updateMode: route.updateMode
        )
        let collector = CommandDataCollector()
        let useWaypointSTDIN = segmentRoute.waypoints.count > 250
        let waypointInputMode: LocationCommandBuilder.WaypointInputMode = useWaypointSTDIN ? .stdin : .arguments
        let arguments = try LocationCommandBuilder.startArguments(
            udid: udid,
            route: segmentRoute,
            waypointInputMode: waypointInputMode
        )
        let waypointSTDINData = useWaypointSTDIN ? try LocationCommandBuilder.waypointSTDINData(route: segmentRoute) : nil
        let waypointInputPipe = useWaypointSTDIN ? Pipe() : nil
        let firstPoint = segmentRoute.waypoints.first.map { "(\($0.lat),\($0.lon))" } ?? "<none>"
        let lastPoint = segmentRoute.waypoints.last.map { "(\($0.lat),\($0.lon))" } ?? "<none>"
        logDebug(
            """
            startRouteSegment: udid=\(udid), routeID=\(route.id.uuidString), \
            segment=\(segmentIndex + 1)/\(segments.count), segmentWaypoints=\(segmentRoute.waypoints.count), \
            waypointInputMode=\(useWaypointSTDIN ? "stdin" : "arguments"), \
            first=\(firstPoint), last=\(lastPoint)
            """
        )
        let runnable = createLongRunningProcess(
            arguments: arguments,
            collector: collector,
            standardInputPipe: waypointInputPipe
        )

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
            self.handleRouteSegmentTermination(
                udid: udid,
                route: route,
                segments: segments,
                segmentIndex: segmentIndex,
                process: process,
                runnable: runnable,
                collector: collector
            )
        }

        do {
            try runnable.process.run()
            logDebug("Route segment process launched: udid=\(udid), routeID=\(route.id.uuidString), pid=\(runnable.process.processIdentifier)")
            if let waypointSTDINData {
                DispatchQueue.global(qos: .userInitiated).async {
                    runnable.inputPipe.fileHandleForWriting.write(waypointSTDINData)
                    try? runnable.inputPipe.fileHandleForWriting.close()
                }
            }
        } catch {
            routeSessions.removeSession(for: udid)
            logDebug("Failed to launch route segment process for udid=\(udid), routeID=\(route.id.uuidString): \(error.localizedDescription)")
            throw error
        }
    }

    private func handleRouteSegmentTermination(
        udid: String,
        route: SavedRoute,
        segments: [[GeoPoint]],
        segmentIndex: Int,
        process: Process,
        runnable: (process: Process, outputPipe: Pipe, errorPipe: Pipe, inputPipe: Pipe),
        collector: CommandDataCollector
    ) {
        runnable.outputPipe.fileHandleForReading.readabilityHandler = nil
        runnable.errorPipe.fileHandleForReading.readabilityHandler = nil

        let remainingOutput = runnable.outputPipe.fileHandleForReading.availableData
        let remainingError = runnable.errorPipe.fileHandleForReading.availableData

        runnable.outputPipe.fileHandleForReading.closeFile()
        runnable.errorPipe.fileHandleForReading.closeFile()
        try? runnable.inputPipe.fileHandleForWriting.close()

        let (output, error) = collector.finalize(remainingOutput: remainingOutput, remainingError: remainingError)
        let combinedMessage = error.isEmpty ? output : error
        logDebug(
            """
            Route segment terminated: udid=\(udid), routeID=\(route.id.uuidString), \
            segment=\(segmentIndex + 1)/\(segments.count), status=\(process.terminationStatus), \
            message=\(summarize(combinedMessage))
            """
        )

        routeSessions.removeSession(for: udid)

        if routeSessions.consumeStopping(udid) {
            routeSessions.setPlaybackState(.idle, for: udid)
            logDebug("Route termination was expected due to stop request for udid=\(udid)")
            return
        }

        if process.terminationStatus != 0 {
            let message = combinedMessage.isEmpty ? "Route process terminated with status \(process.terminationStatus)." : combinedMessage
            routeSessions.setPlaybackState(.failed(message: message), for: udid)
            logDebug("Route failed for udid=\(udid), routeID=\(route.id.uuidString): \(summarize(message))")
            return
        }

        let nextIndex = segmentIndex + 1
        if nextIndex >= segments.count {
            if !runningExternalLocationStartPIDs(for: udid).isEmpty {
                routeSessions.setPlaybackState(.running(routeID: route.id), for: udid)
                logDebug(
                    """
                    Route process exited but external route-start process is still active; \
                    keeping playback running for udid=\(udid), routeID=\(route.id.uuidString)
                    """
                )
                return
            }
            routeSessions.setPlaybackState(.finished, for: udid)
            logDebug("Route completed for udid=\(udid), routeID=\(route.id.uuidString)")
            return
        }

        do {
            try startRouteSegment(
                udid: udid,
                route: route,
                segments: segments,
                segmentIndex: nextIndex
            )
        } catch {
            routeSessions.setPlaybackState(.failed(message: error.localizedDescription), for: udid)
            logDebug("Failed to start next segment for udid=\(udid), routeID=\(route.id.uuidString): \(error.localizedDescription)")
        }
    }

    func pauseRoute(udid: String) throws {
        if let session = routeSessions.session(for: udid), session.process.isRunning {
            let result = kill(session.process.processIdentifier, SIGSTOP)
            guard result == 0 else {
                logDebug("pauseRoute failed for udid=\(udid), pid=\(session.process.processIdentifier)")
                throw SimctlError.commandFailed("Failed to pause route session.")
            }

            routeSessions.setPlaybackState(.paused(routeID: session.routeID), for: udid)
            logDebug("pauseRoute success for udid=\(udid), pid=\(session.process.processIdentifier), routeID=\(session.routeID.uuidString)")
            return
        }

        guard signalExternalLocationStartProcesses(for: udid, signal: SIGSTOP, signalName: "SIGSTOP") else {
            routeSessions.setPlaybackState(.finished, for: udid)
            logDebug("pauseRoute ignored: no active route process for udid=\(udid), marking finished")
            return
        }

        if let routeID = routeSessions.routeID(for: udid) {
            routeSessions.setPlaybackState(.paused(routeID: routeID), for: udid)
            logDebug("pauseRoute success via external process signal for udid=\(udid), routeID=\(routeID.uuidString)")
        } else {
            logDebug("pauseRoute signaled external process for udid=\(udid), but routeID was unknown")
        }
    }

    func resumeRoute(udid: String) throws {
        if let session = routeSessions.session(for: udid), session.process.isRunning {
            let result = kill(session.process.processIdentifier, SIGCONT)
            guard result == 0 else {
                logDebug("resumeRoute failed for udid=\(udid), pid=\(session.process.processIdentifier)")
                throw SimctlError.commandFailed("Failed to resume route session.")
            }

            routeSessions.setPlaybackState(.running(routeID: session.routeID), for: udid)
            logDebug("resumeRoute success for udid=\(udid), pid=\(session.process.processIdentifier), routeID=\(session.routeID.uuidString)")
            return
        }

        guard signalExternalLocationStartProcesses(for: udid, signal: SIGCONT, signalName: "SIGCONT") else {
            routeSessions.setPlaybackState(.finished, for: udid)
            logDebug("resumeRoute ignored: no active route process for udid=\(udid), marking finished")
            return
        }

        if let routeID = routeSessions.routeID(for: udid) {
            routeSessions.setPlaybackState(.running(routeID: routeID), for: udid)
            logDebug("resumeRoute success via external process signal for udid=\(udid), routeID=\(routeID.uuidString)")
        } else {
            logDebug("resumeRoute signaled external process for udid=\(udid), but routeID was unknown")
        }
    }

    func stopRoute(udid: String) async {
        await stopRoute(udid: udid, shouldClearLocation: true)
    }

    private func stopRoute(udid: String, shouldClearLocation: Bool) async {
        logDebug("stopRoute requested: udid=\(udid), shouldClearLocation=\(shouldClearLocation)")
        routeSessions.markStopping(udid)
        if let session = routeSessions.session(for: udid) {
            routeSessions.setPlaybackState(.idle, for: udid)

            if session.process.isRunning {
                session.process.terminate()
                logDebug("Sent terminate to route process pid=\(session.process.processIdentifier) for udid=\(udid)")

                for _ in 0..<10 {
                    if !session.process.isRunning {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                if session.process.isRunning {
                    _ = kill(session.process.processIdentifier, SIGKILL)
                    logDebug("Sent SIGKILL to route process pid=\(session.process.processIdentifier) for udid=\(udid)")
                }
            }

            // Wait briefly so the termination handler can drain pipes and clear session state.
            for _ in 0..<10 {
                if routeSessions.session(for: udid) == nil {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        routeSessions.removeSession(for: udid)
        _ = routeSessions.consumeStopping(udid)
        routeSessions.setPlaybackState(.idle, for: udid)

        await terminateExternalLocationStartProcessesAsync(for: udid)

        if shouldClearLocation {
            // Best-effort cleanup for explicit stop actions.
            try? await clearLocation(udid: udid)
        }
        logDebug("stopRoute finished: udid=\(udid), shouldClearLocation=\(shouldClearLocation)")
    }

    func playbackState(udid: String) -> PlaybackState {
        routeSessions.playbackState(for: udid)
    }
}
