import Foundation
import Combine

enum SimulatorLogStreamState: Equatable {
    case stopped
    case starting
    case streaming(pid: Int32)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .streaming:
            return true
        case .stopped, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .stopped:
            return L10n.t("Stopped")
        case .starting:
            return L10n.t("Starting")
        case .streaming:
            return L10n.t("Streaming")
        case .failed:
            return L10n.t("Failed")
        }
    }
}

struct SimulatorLogDevice: Identifiable, Equatable {
    let udid: String
    let name: String
    let runtimeName: String
    let isBooted: Bool
    let state: SimulatorLogStreamState

    var id: String { udid }
}

@MainActor
final class SimulatorLogStore: ObservableObject {
    static let shared = SimulatorLogStore()

    static let maxEntryCount = 50_000
    static let maxDisplayedEntryCount = 2_000
    private static let maxFilterScanCount = 20_000
    private static let maxPendingLineCount = 8_000
    private static let maxLinesPerFlush = 1_500

    @Published private(set) var entries: [SimulatorLogEntry] = []
    @Published private(set) var displayedEntries: [SimulatorLogEntry] = []
    @Published private(set) var matchingEntryCount = 0
    @Published private(set) var devices: [SimulatorLogDevice] = []
    @Published private(set) var discoveredSubsystems: [String] = []
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var feedback: FeedbackMessage?

    @Published var selectedLevels: Set<SimulatorLogLevel> = Set(SimulatorLogLevel.allCases)
    @Published var selectedSubsystems: Set<String> = []
    @Published var searchText = "" {
        didSet {
            filterRevision &+= 1
            scheduleDisplayRefresh()
        }
    }
    @Published var selectedEntryIDs: Set<UUID> = []
    @Published var isFollowingTail = true {
        didSet {
            updateFollowSelection()
        }
    }
    @Published var isNewestFirst = false {
        didSet {
            filterRevision &+= 1
            scheduleDisplayRefresh(immediate: true)
        }
    }
    @Published private(set) var isGlobalStreamingEnabled = false

    private let streamService: SimulatorLogStreamService
    private var streamHandles: [String: SimulatorLogStreamHandle] = [:]
    private var streamTokens: [String: UUID] = [:]
    private var streamStates: [String: SimulatorLogStreamState] = [:]
    private var deviceRecords: [String: DeviceRecord] = [:]
    private var subsystemSet: Set<String> = []
    private var pendingLines: [(line: String, udid: String, deviceName: String)] = []
    private var pendingMalformedLineCount = 0
    private var pendingFlushTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var streamRestartTask: Task<Void, Never>?
    private var filterRevision = 0

    init(streamService: SimulatorLogStreamService = .shared) {
        self.streamService = streamService
    }

    var isAnyStreamActive: Bool {
        streamHandles.values.contains { $0.isRunning }
    }

    var selectedEntries: [SimulatorLogEntry] {
        guard !selectedEntryIDs.isEmpty else { return [] }
        return entries.filter { selectedEntryIDs.contains($0.id) }
    }

    var filteredEntries: [SimulatorLogEntry] {
        displayedEntries
    }

    private var streamLevelArgument: String {
        if selectedLevels.contains(.debug) {
            return "debug"
        }
        if selectedLevels.contains(.info) {
            return "info"
        }
        return "default"
    }

    private var streamPredicate: String? {
        let logTypes = Set(selectedLevels.flatMap(\.predicateLogTypes))
            .sorted()

        var clauses: [String] = []
        if logTypes.isEmpty {
            clauses.append("processIdentifier == -1")
        } else if logTypes.count < SimulatorLogLevel.allCases.flatMap(\.predicateLogTypes).count {
            clauses.append(orPredicate(field: "logType", values: logTypes))
        }

        if !selectedSubsystems.isEmpty {
            clauses.append(orPredicate(field: "subsystem", values: selectedSubsystems.sorted()))
        }

        guard !clauses.isEmpty else {
            return nil
        }
        return clauses.map { "(\($0))" }.joined(separator: " AND ")
    }

    private func orPredicate(field: String, values: [String]) -> String {
        values.map { "\(field) == \"\(escapedPredicateValue($0))\"" }
            .joined(separator: " OR ")
    }

    private func escapedPredicateValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func syncDevices(_ records: [DeviceRecord]) {
        deviceRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.udid, $0) })
        let currentUDIDs = Set(records.map(\.udid))

        for udid in streamHandles.keys where !currentUDIDs.contains(udid) {
            stopStream(udid: udid)
        }

        for record in records where !record.isBooted && streamHandles[record.udid] != nil {
            stopStream(udid: record.udid)
        }

        refreshDeviceSnapshots()

        if isGlobalStreamingEnabled {
            for record in records where record.isBooted {
                startStream(for: record)
            }
        }
    }

    func startGlobalStreaming() {
        isGlobalStreamingEnabled = true
        for record in deviceRecords.values where record.isBooted {
            startStream(for: record)
        }
    }

    func stopGlobalStreaming() {
        isGlobalStreamingEnabled = false
        stopAllStreams()
    }

    func toggleGlobalStreaming() {
        if isGlobalStreamingEnabled || isAnyStreamActive {
            stopGlobalStreaming()
        } else {
            startGlobalStreaming()
        }
    }

    func toggleStream(for record: DeviceRecord) {
        if streamHandles[record.udid] != nil {
            stopStream(udid: record.udid)
        } else {
            startStream(for: record)
        }
    }

    func startStream(for record: DeviceRecord) {
        guard record.isBooted else {
            feedback = FeedbackMessage(level: .warning, text: L10n.t("Only booted simulators can stream logs."))
            setStreamState(.stopped, for: record.udid)
            return
        }

        guard streamHandles[record.udid] == nil else {
            return
        }

        let streamToken = UUID()
        streamTokens[record.udid] = streamToken
        setStreamState(.starting, for: record.udid)
        do {
            let handle = try streamService.startStream(
                udid: record.udid,
                deviceName: record.name,
                predicate: streamPredicate,
                levelArgument: streamLevelArgument,
                onLines: { [weak self] lines in
                    Task { @MainActor [weak self] in
                        self?.enqueueLines(lines, udid: record.udid, deviceName: record.name)
                    }
                },
                onDiagnostic: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.addDiagnostic(message, udid: record.udid)
                    }
                },
                onTermination: { [weak self] status, wasStoppedExplicitly in
                    Task { @MainActor [weak self] in
                        self?.handleTermination(
                            udid: record.udid,
                            token: streamToken,
                            status: status,
                            wasStoppedExplicitly: wasStoppedExplicitly
                        )
                    }
                }
            )
            streamHandles[record.udid] = handle
            setStreamState(.streaming(pid: handle.processIdentifier), for: record.udid)
        } catch {
            let message = error.localizedDescription
            streamHandles.removeValue(forKey: record.udid)
            if streamTokens[record.udid] == streamToken {
                streamTokens.removeValue(forKey: record.udid)
            }
            setStreamState(.failed(message), for: record.udid)
            feedback = FeedbackMessage(level: .error, text: message)
            addDiagnostic(message, udid: record.udid)
        }
    }

    func stopStream(udid: String) {
        streamHandles.removeValue(forKey: udid)?.stop()
        streamTokens.removeValue(forKey: udid)
        setStreamState(.stopped, for: udid)
    }

    func stopAllStreams() {
        for udid in Array(streamHandles.keys) {
            stopStream(udid: udid)
        }
    }

    func clearEntries() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        entries.removeAll(keepingCapacity: true)
        displayedEntries.removeAll(keepingCapacity: true)
        matchingEntryCount = 0
        selectedEntryIDs.removeAll(keepingCapacity: true)
        subsystemSet.removeAll(keepingCapacity: true)
        discoveredSubsystems.removeAll(keepingCapacity: true)
        pendingLines.removeAll(keepingCapacity: true)
        pendingMalformedLineCount = 0
    }

    func clearFeedback() {
        feedback = nil
    }

    func setLevel(_ level: SimulatorLogLevel, isEnabled: Bool) {
        if isEnabled {
            selectedLevels.insert(level)
        } else {
            selectedLevels.remove(level)
        }
        filterRevision &+= 1
        scheduleDisplayRefresh()
        scheduleStreamRestartForFilterChange()
    }

    func selectAllLevels() {
        selectedLevels = Set(SimulatorLogLevel.allCases)
        filterRevision &+= 1
        scheduleDisplayRefresh()
        scheduleStreamRestartForFilterChange()
    }

    func clearLevelSelection() {
        selectedLevels.removeAll()
        filterRevision &+= 1
        scheduleDisplayRefresh()
        scheduleStreamRestartForFilterChange()
    }

    func setSubsystem(_ subsystem: String, isSelected: Bool) {
        if isSelected {
            selectedSubsystems.insert(subsystem)
        } else {
            selectedSubsystems.remove(subsystem)
        }
        filterRevision &+= 1
        scheduleDisplayRefresh()
        scheduleStreamRestartForFilterChange()
    }

    func clearSubsystemSelection() {
        selectedSubsystems.removeAll(keepingCapacity: true)
        filterRevision &+= 1
        scheduleDisplayRefresh()
        scheduleStreamRestartForFilterChange()
    }

    func exportSelectedLogText() -> String {
        SimulatorLogExporter.logText(entries: selectedEntries)
    }

    func exportSelectedJSONData() throws -> Data {
        try SimulatorLogExporter.jsonData(entries: selectedEntries)
    }

    func streamState(for udid: String) -> SimulatorLogStreamState {
        streamStates[udid] ?? .stopped
    }

    func isStreaming(udid: String) -> Bool {
        streamHandles[udid]?.isRunning == true
    }

    func ingestLine(_ line: String, udid: String, deviceName: String) {
        switch SimulatorLogParser.parseLine(line, simulatorUDID: udid, simulatorName: deviceName) {
        case .entry(let entry):
            appendEntry(entry)
        case .malformed(let rawLine):
            addDiagnostic(L10n.f("Malformed log line: %@", rawLine), udid: udid)
        }
    }

    func enqueueLines(_ lines: [String], udid: String, deviceName: String) {
        guard !lines.isEmpty else { return }

        if pendingLines.count + lines.count > Self.maxPendingLineCount {
            let overflow = pendingLines.count + lines.count - Self.maxPendingLineCount
            pendingLines.removeFirst(min(overflow, pendingLines.count))
            pendingMalformedLineCount += overflow
        }

        pendingLines.append(contentsOf: lines.map { ($0, udid, deviceName) })
        schedulePendingFlush()
    }

    func appendEntry(_ entry: SimulatorLogEntry) {
        appendEntries([entry], malformedCount: 0)
    }

    private func schedulePendingFlush() {
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.flushPendingLines()
        }
    }

    private func scheduleStreamRestartForFilterChange() {
        guard !streamHandles.isEmpty else { return }
        streamRestartTask?.cancel()
        streamRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.streamRestartTask = nil
            self?.restartActiveStreamsForCurrentFilters()
        }
    }

    private func restartActiveStreamsForCurrentFilters() {
        let activeUDIDs = Array(streamHandles.keys)
        guard !activeUDIDs.isEmpty else { return }

        for udid in activeUDIDs {
            stopStream(udid: udid)
        }

        for udid in activeUDIDs {
            guard let record = deviceRecords[udid], record.isBooted else { continue }
            startStream(for: record)
        }
    }

    private func flushPendingLines() {
        pendingFlushTask = nil
        guard !pendingLines.isEmpty || pendingMalformedLineCount > 0 else { return }

        let batchSize = min(pendingLines.count, Self.maxLinesPerFlush)
        let batch = Array(pendingLines.prefix(batchSize))
        let droppedMalformedCount = pendingMalformedLineCount
        pendingLines.removeFirst(batchSize)
        pendingMalformedLineCount = 0

        var parsedEntries: [SimulatorLogEntry] = []
        var malformedCount = droppedMalformedCount

        parsedEntries.reserveCapacity(batch.count)
        for item in batch {
            switch SimulatorLogParser.parseLine(item.line, simulatorUDID: item.udid, simulatorName: item.deviceName) {
            case .entry(let entry):
                parsedEntries.append(entry)
            case .malformed:
                malformedCount += 1
            }
        }

        appendEntries(parsedEntries, malformedCount: malformedCount)

        if !pendingLines.isEmpty {
            schedulePendingFlush()
        }
    }

    private func appendEntries(_ newEntries: [SimulatorLogEntry], malformedCount: Int) {
        if !newEntries.isEmpty {
            entries.append(contentsOf: newEntries)
            if entries.count > Self.maxEntryCount {
                entries.removeFirst(entries.count - Self.maxEntryCount)
            }

            var subsystemChanged = false
            for entry in newEntries where !entry.subsystem.isEmpty {
                if subsystemSet.insert(entry.subsystem).inserted {
                    subsystemChanged = true
                }
            }
            if subsystemChanged {
                discoveredSubsystems = subsystemSet.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            }
        }

        if malformedCount > 0 {
            let message = L10n.f("Skipped %d malformed log lines.", malformedCount)
            diagnostics.append(message)
            if diagnostics.count > 100 {
                diagnostics.removeFirst(diagnostics.count - 100)
            }
        }

        if !selectedEntryIDs.isEmpty {
            let validIDs = Set(entries.suffix(Self.maxDisplayedEntryCount * 2).map(\.id))
            selectedEntryIDs = selectedEntryIDs.intersection(validIDs)
        }

        scheduleDisplayRefresh()
    }

    private func scheduleDisplayRefresh(immediate: Bool = false) {
        if immediate {
            displayRefreshTask?.cancel()
            displayRefreshTask = nil
            refreshDisplayedEntries()
            return
        }

        guard displayRefreshTask == nil else { return }
        let revision = filterRevision
        displayRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.displayRefreshTask = nil
            guard self?.filterRevision == revision else {
                self?.scheduleDisplayRefresh(immediate: true)
                return
            }
            self?.refreshDisplayedEntries()
        }
    }

    private func refreshDisplayedEntries() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultFilters = selectedLevels.count == SimulatorLogLevel.allCases.count
            && selectedSubsystems.isEmpty
            && query.isEmpty

        if defaultFilters {
            matchingEntryCount = entries.count
            updateDisplayedEntries(Array(entries.suffix(Self.maxDisplayedEntryCount)))
            return
        }

        var matches: [SimulatorLogEntry] = []
        matches.reserveCapacity(Self.maxDisplayedEntryCount)
        var matchCount = 0

        for entry in entries.suffix(Self.maxFilterScanCount).reversed() {
            guard matchesFilter(entry, query: query) else { continue }
            matchCount += 1
            if matches.count < Self.maxDisplayedEntryCount {
                matches.append(entry)
            }
        }

        matchingEntryCount = matchCount
        updateDisplayedEntries(Array(matches.reversed()))
    }

    private func updateDisplayedEntries(_ orderedOldestFirst: [SimulatorLogEntry]) {
        displayedEntries = isNewestFirst ? Array(orderedOldestFirst.reversed()) : orderedOldestFirst
        updateFollowSelection()
    }

    private func updateFollowSelection() {
        guard isFollowingTail else { return }
        let targetEntry = isNewestFirst ? displayedEntries.first : displayedEntries.last
        guard let targetEntry else { return }
        selectedEntryIDs = [targetEntry.id]
    }

    private func matchesFilter(_ entry: SimulatorLogEntry, query: String) -> Bool {
        if !selectedLevels.contains(entry.level) {
            return false
        }

        if !selectedSubsystems.isEmpty, !selectedSubsystems.contains(entry.subsystem) {
            return false
        }

        guard !query.isEmpty else {
            return true
        }

        return entry.searchText.localizedCaseInsensitiveContains(query)
    }

    private func addDiagnostic(_ message: String, udid: String) {
        let prefix = deviceRecords[udid]?.name ?? udid
        let entry = "[\(prefix)] \(message)"
        diagnostics.append(entry)
        if diagnostics.count > 100 {
            diagnostics.removeFirst(diagnostics.count - 100)
        }
        RouteDebugLogStore.shared.log("SimulatorLogStore: \(entry)")
    }

    private func handleTermination(udid: String, token: UUID, status: Int32, wasStoppedExplicitly: Bool) {
        guard streamTokens[udid] == token else {
            return
        }

        streamHandles.removeValue(forKey: udid)
        streamTokens.removeValue(forKey: udid)

        if wasStoppedExplicitly || status == SIGTERM || status == 0 {
            setStreamState(.stopped, for: udid)
        } else {
            let message = L10n.f("Log stream ended with status %d.", Int(status))
            setStreamState(.failed(message), for: udid)
            feedback = FeedbackMessage(level: .warning, text: message)
            addDiagnostic(message, udid: udid)
        }

        if isGlobalStreamingEnabled, let record = deviceRecords[udid], record.isBooted {
            startStream(for: record)
        }
    }

    private func setStreamState(_ state: SimulatorLogStreamState, for udid: String) {
        streamStates[udid] = state
        refreshDeviceSnapshots()
    }

    private func refreshDeviceSnapshots() {
        devices = deviceRecords.values
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { record in
                SimulatorLogDevice(
                    udid: record.udid,
                    name: record.name,
                    runtimeName: record.runtimeName,
                    isBooted: record.isBooted,
                    state: streamStates[record.udid] ?? .stopped
                )
            }
    }
}
