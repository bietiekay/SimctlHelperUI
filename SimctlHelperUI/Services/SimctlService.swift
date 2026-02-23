//
//  SimctlService.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import Foundation

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

class SimctlService {
    static let shared = SimctlService()
    
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
            // Use thread-safe data collection
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
                    // EOF reached, stop reading but don't close yet
                    handle.readabilityHandler = nil
                }
            }
            
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    collector.appendError(data)
                } else {
                    // EOF reached, stop reading but don't close yet
                    handle.readabilityHandler = nil
                }
            }
            
            process.terminationHandler = { process in
                // Close handlers first
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                
                // Read any remaining data before closing (if handles are still valid)
                // Use availableData which is safer and doesn't throw
                let remainingOutput = outputPipe.fileHandleForReading.availableData
                let remainingError = errorPipe.fileHandleForReading.availableData
                
                // Close file handles
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
                
                // Set timeout
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
    
    // MARK: - Fetch Device List
    
    func fetchDeviceList() async throws -> SimctlListResponse {
        let result = try await executeCommand(["list", "-j"])
        
        guard let data = result.output.data(using: .utf8) else {
            throw SimctlError.invalidJSON
        }
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(SimctlListResponse.self, from: data)
        
        return response
    }
    
    // MARK: - Clone Device
    
    func cloneDevice(udid: String, name: String) async throws {
        guard !name.isEmpty else {
            throw SimctlError.invalidDeviceName
        }
        
        // Validate name doesn't contain invalid characters
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
}
