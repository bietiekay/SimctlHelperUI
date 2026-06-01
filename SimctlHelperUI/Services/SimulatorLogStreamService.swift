import Foundation

enum SimulatorLogStreamError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        }
    }
}

final class SimulatorLogStreamHandle: @unchecked Sendable {
    let udid: String
    let deviceName: String

    private let process: Process
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let stopped = LockedFlag()

    nonisolated init(
        udid: String,
        deviceName: String,
        process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) {
        self.udid = udid
        self.deviceName = deviceName
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
    }

    nonisolated var isRunning: Bool {
        process.isRunning
    }

    nonisolated var processIdentifier: Int32 {
        process.processIdentifier
    }

    nonisolated func stop() {
        guard stopped.setIfNeeded() else { return }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    nonisolated func markStoppedByTermination() {
        _ = stopped.setIfNeeded()
    }

    nonisolated var wasStoppedExplicitly: Bool {
        stopped.value
    }
}

final class SimulatorLogStreamService {
    nonisolated static let shared = SimulatorLogStreamService()

    nonisolated private init() {}

    nonisolated func startStream(
        udid: String,
        deviceName: String,
        predicate: String?,
        levelArgument: String,
        onLines: @escaping @Sendable ([String]) -> Void,
        onDiagnostic: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32, Bool) -> Void
    ) throws -> SimulatorLogStreamHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = [
            "simctl",
            "spawn",
            udid,
            "log",
            "stream",
            "--style",
            "ndjson",
            "--level",
            levelArgument,
            "--color",
            "none",
        ]
        if let predicate, !predicate.isEmpty {
            arguments.append(contentsOf: ["--predicate", predicate])
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = Pipe()

        let outputCollector = SimulatorLogLineCollector()
        let errorCollector = SimulatorLogLineCollector()
        let handle = SimulatorLogStreamHandle(
            udid: udid,
            deviceName: deviceName,
            process: process,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let lines = outputCollector.append(data)
            if !lines.isEmpty {
                onLines(lines)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            for line in errorCollector.append(data) where !line.isEmpty {
                onDiagnostic(line)
            }
        }

        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOutput = outputPipe.fileHandleForReading.availableData
            let remainingError = errorPipe.fileHandleForReading.availableData
            var outputLines = outputCollector.append(remainingOutput)
            if let line = outputCollector.flush() {
                outputLines.append(line)
            }
            if !outputLines.isEmpty {
                onLines(outputLines)
            }
            for line in errorCollector.append(remainingError) where !line.isEmpty {
                onDiagnostic(line)
            }
            if let line = errorCollector.flush(), !line.isEmpty {
                onDiagnostic(line)
            }

            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            let wasStoppedExplicitly = handle.wasStoppedExplicitly
            handle.markStoppedByTermination()
            onTermination(process.terminationStatus, wasStoppedExplicitly)
        }

        do {
            try process.run()
            return handle
        } catch {
            throw SimulatorLogStreamError.launchFailed(error.localizedDescription)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var flag = false

    nonisolated init() {}

    nonisolated var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    nonisolated func setIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !flag else { return false }
        flag = true
        return true
    }
}

private final class SimulatorLogLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var buffer = SimulatorLogLineBuffer()

    nonisolated init() {}

    nonisolated func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.append(data)
    }

    nonisolated func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.flush()
    }
}
