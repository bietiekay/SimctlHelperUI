import Foundation

extension Notification.Name {
    static let routeDebugLogDidChange = Notification.Name("RouteDebugLogDidChange")
}

final class RouteDebugLogStore: @unchecked Sendable {
    nonisolated static let shared = RouteDebugLogStore()

    private let lock = NSLock()
    nonisolated(unsafe) private var entries: [String] = []
    private let maxEntries = 1_500

    private init() {}

    nonisolated func log(_ message: String) {
        let entry = "[\(timestamp())] [\(Thread.isMainThread ? "main" : "bg")] \(message)"

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        fputs("[RouteDebug] \(entry)\n", stderr)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .routeDebugLogDidChange, object: nil)
        }
    }

    nonisolated func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }

    nonisolated func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .routeDebugLogDidChange, object: nil)
        }
    }

    nonisolated private func timestamp() -> String {
        let time = Date().timeIntervalSince1970
        let seconds = Int(time)
        let milliseconds = Int((time - Double(seconds)) * 1_000)
        return "\(seconds).\(String(format: "%03d", milliseconds))"
    }
}
