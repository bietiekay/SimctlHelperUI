import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SimulatorLogWindowView: View {
    private enum ExportKind {
        case log
        case json
    }

    @ObservedObject var logStore: SimulatorLogStore
    @ObservedObject var deviceStore: DeviceStore

    @State private var subsystemSearchText = ""
    @State private var detailEntry: SimulatorLogEntry?
    @State private var showExporter = false
    @State private var exportKind: ExportKind = .log
    @State private var exportDocument = SimulatorLogExportDocument(data: Data())

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            logTable
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    logStore.toggleGlobalStreaming()
                } label: {
                    Label(
                        globalToggleTitle,
                        systemImage: logStore.isGlobalStreamingEnabled || logStore.isAnyStreamActive ? "stop.circle" : "play.circle"
                    )
                }
                .disabled(!logStore.isGlobalStreamingEnabled && !hasBootedDevices)

                Button {
                    logStore.clearEntries()
                } label: {
                    Label(L10n.t("Clear"), systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)

                Toggle(isOn: $logStore.isFollowingTail) {
                    Label(L10n.t("Follow Latest"), systemImage: logStore.isNewestFirst ? "arrow.up.to.line" : "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help(L10n.t("Keep the newest log entry visible."))

                Toggle(isOn: $logStore.isNewestFirst) {
                    Label(L10n.t("Newest First"), systemImage: logStore.isNewestFirst ? "arrow.down" : "arrow.up")
                }
                .toggleStyle(.button)
                .help(L10n.t("Show newest messages at the top."))

                Menu {
                    Button(L10n.t("Export Selected as .log")) {
                        beginExport(.log)
                    }

                    Button(L10n.t("Export Selected as .json")) {
                        beginExport(.json)
                    }
                } label: {
                    Label(L10n.t("Export Selected"), systemImage: "square.and.arrow.up")
                }
                .disabled(logStore.selectedEntryIDs.isEmpty)
            }
        }
        .sheet(item: $detailEntry) { entry in
            SimulatorLogDetailView(entry: entry)
                .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 620)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                logStore.clearFeedback()
                RouteDebugLogStore.shared.log("SimulatorLogWindowView export failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            logStore.syncDevices(deviceStore.devices)
        }
    }

    private var sidebar: some View {
        List {
            Section(L10n.t("Sources")) {
                Button {
                    logStore.toggleGlobalStreaming()
                } label: {
                    Label(globalToggleTitle, systemImage: logStore.isGlobalStreamingEnabled || logStore.isAnyStreamActive ? "stop.fill" : "play.fill")
                }
                .disabled(!logStore.isGlobalStreamingEnabled && !hasBootedDevices)

                ForEach(logStore.devices) { device in
                    SimulatorLogSourceRow(device: device) {
                        guard let record = deviceStore.device(for: device.udid) else { return }
                        logStore.toggleStream(for: record)
                    }
                }
            }

            Section(L10n.t("Levels")) {
                HStack {
                    Button(L10n.t("All")) {
                        logStore.selectAllLevels()
                    }
                    Button(L10n.t("None")) {
                        logStore.clearLevelSelection()
                    }
                }

                ForEach(SimulatorLogLevel.allCases) { level in
                    Toggle(
                        level.title,
                        isOn: Binding(
                            get: { logStore.selectedLevels.contains(level) },
                            set: { logStore.setLevel(level, isEnabled: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Section(L10n.t("Subsystems")) {
                TextField(L10n.t("Filter Subsystems"), text: $subsystemSearchText)
                    .textFieldStyle(.roundedBorder)

                Button(L10n.t("Show All Subsystems")) {
                    logStore.clearSubsystemSelection()
                }
                .disabled(logStore.selectedSubsystems.isEmpty)

                if filteredSubsystems.isEmpty {
                    Text(L10n.t("Subsystems appear as live logs arrive."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredSubsystems, id: \.self) { subsystem in
                        Toggle(
                            subsystem,
                            isOn: Binding(
                                get: { logStore.selectedSubsystems.contains(subsystem) },
                                set: { logStore.setSubsystem(subsystem, isSelected: $0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                    }
                }
            }

            if !logStore.diagnostics.isEmpty {
                Section(L10n.t("Diagnostics")) {
                    ForEach(logStore.diagnostics.suffix(5), id: \.self) { diagnostic in
                        Text(diagnostic)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var logTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.t("Simulator Logs"))
                    .font(.headline)
                Text(L10n.f("%d visible", logStore.displayedEntries.count))
                    .foregroundStyle(.secondary)
                if logStore.matchingEntryCount > logStore.displayedEntries.count {
                    Text(L10n.f("%d matching", logStore.matchingEntryCount))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.f("%d total", logStore.entries.count))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.t("Search Logs"), text: $logStore.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            if logStore.displayedEntries.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("No log entries"), systemImage: "list.bullet.rectangle")
                } description: {
                    Text(L10n.t("Start logging for a booted simulator or adjust the current filters."))
                }
            } else {
                logList
            }

            FeedbackStatusBarView(message: logStore.feedback) {
                logStore.clearFeedback()
            }
        }
    }

    private var filteredSubsystems: [String] {
        let query = subsystemSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return logStore.discoveredSubsystems
        }
        return logStore.discoveredSubsystems.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasBootedDevices: Bool {
        logStore.devices.contains { $0.isBooted }
    }

    private var globalToggleTitle: String {
        logStore.isGlobalStreamingEnabled || logStore.isAnyStreamActive ? L10n.t("Stop All Logs") : L10n.t("Start All Logs")
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SimulatorLogHeaderRow()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(logStore.displayedEntries) { entry in
                            SimulatorLogRow(
                                entry: entry,
                                isSelected: logStore.selectedEntryIDs.contains(entry.id)
                            )
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                logStore.selectedEntryIDs = [entry.id]
                                detailEntry = entry
                            }
                            .onTapGesture {
                                selectEntry(entry)
                            }
                            .contextMenu {
                                Button(L10n.t("Show Details")) {
                                    detailEntry = entry
                                }

                                Button(L10n.t("Copy Messages")) {
                                    let selection = logStore.selectedEntryIDs.isEmpty ? [entry.id] : Array(logStore.selectedEntryIDs)
                                    copyMessages(for: Set(selection))
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                scrollToFollowEdge(proxy)
            }
            .onChange(of: followScrollToken) { _, _ in
                scrollToFollowEdge(proxy)
            }
            .onChange(of: logStore.isFollowingTail) { _, _ in
                scrollToFollowEdge(proxy)
            }
            .onChange(of: logStore.isNewestFirst) { _, _ in
                scrollToFollowEdge(proxy)
            }
        }
    }

    private var followScrollToken: String {
        let edgeID = logStore.isNewestFirst
            ? logStore.displayedEntries.first?.id.uuidString
            : logStore.displayedEntries.last?.id.uuidString
        return "\(logStore.isNewestFirst)-\(logStore.displayedEntries.count)-\(edgeID ?? "")"
    }

    private var exportContentType: UTType {
        switch exportKind {
        case .log:
            return UTType(filenameExtension: "log") ?? .plainText
        case .json:
            return .json
        }
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        switch exportKind {
        case .log:
            return "simulator-logs-\(formatter.string(from: Date())).log"
        case .json:
            return "simulator-logs-\(formatter.string(from: Date())).json"
        }
    }

    private func beginExport(_ kind: ExportKind) {
        exportKind = kind
        do {
            switch kind {
            case .log:
                exportDocument = SimulatorLogExportDocument(data: Data(logStore.exportSelectedLogText().utf8))
            case .json:
                exportDocument = SimulatorLogExportDocument(data: try logStore.exportSelectedJSONData())
            }
            showExporter = true
        } catch {
            RouteDebugLogStore.shared.log("SimulatorLogWindowView export preparation failed: \(error.localizedDescription)")
        }
    }

    private func openDetail(for selection: Set<UUID>) {
        guard let id = selection.first,
              let entry = logStore.entries.first(where: { $0.id == id }) else {
            return
        }
        detailEntry = entry
    }

    private func copyMessages(for selection: Set<UUID>) {
        let entries = logStore.entries.filter { selection.contains($0.id) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SimulatorLogExporter.logText(entries: entries), forType: .string)
    }

    private func selectEntry(_ entry: SimulatorLogEntry) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if logStore.selectedEntryIDs.contains(entry.id) {
                logStore.selectedEntryIDs.remove(entry.id)
            } else {
                logStore.selectedEntryIDs.insert(entry.id)
            }
        } else {
            logStore.selectedEntryIDs = [entry.id]
        }
    }

    private func timeText(for entry: SimulatorLogEntry) -> String {
        if !entry.timestampText.isEmpty {
            return entry.timestampText
        }
        return "-"
    }

    private func scrollToFollowEdge(_ proxy: ScrollViewProxy) {
        guard logStore.isFollowingTail else { return }
        let targetID = logStore.isNewestFirst
            ? logStore.displayedEntries.first?.id
            : logStore.displayedEntries.last?.id
        guard let targetID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: logStore.isNewestFirst ? .top : .bottom)
        }
    }
}

private struct SimulatorLogHeaderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.t("Time"))
                .frame(width: 150, alignment: .leading)
            Text(L10n.t("Level"))
                .frame(width: 72, alignment: .leading)
            Text(L10n.t("Process"))
                .frame(width: 140, alignment: .leading)
            Text(L10n.t("Subsystem"))
                .frame(width: 210, alignment: .leading)
            Text(L10n.t("Message"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct SimulatorLogRow: View {
    let entry: SimulatorLogEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.timestampText.isEmpty ? "-" : entry.timestampText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(entry.level.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.level.displayColor)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            Text(entry.processText.isEmpty ? "-" : entry.processText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text(entry.subsystemCategoryText.isEmpty ? "-" : entry.subsystemCategoryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)

            Text(entry.message.isEmpty ? "-" : entry.message)
                .foregroundStyle(entry.level.messageColor)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }
}

private struct SimulatorLogSourceRow: View {
    let device: SimulatorLogDevice
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onToggle()
            } label: {
                Image(systemName: device.state.isActive ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(device.state.isActive ? L10n.t("Stop Logs") : L10n.t("Start Logs"))
            .disabled(!device.isBooted && !device.state.isActive)
        }
    }

    private var statusText: String {
        if !device.isBooted {
            return L10n.t("Simulator is shutdown")
        }

        switch device.state {
        case .streaming(let pid):
            return L10n.f("Streaming, pid %d", Int(pid))
        case .failed(let message):
            return message
        default:
            return device.state.title
        }
    }

    private var statusColor: Color {
        if !device.isBooted {
            return .gray
        }

        switch device.state {
        case .stopped:
            return .gray
        case .starting:
            return .orange
        case .streaming:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct SimulatorLogDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: SimulatorLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Log Message"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(L10n.t("Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow(L10n.t("Time"), entry.timestampText)
                detailRow(L10n.t("Level"), entry.level.title)
                detailRow(L10n.t("Simulator"), entry.simulatorName)
                detailRow("UDID", entry.simulatorUDID)
                detailRow(L10n.t("Process"), entry.processText)
                detailRow(L10n.t("Subsystem"), entry.subsystemCategoryText)
                detailRow(L10n.t("Sender"), entry.sender)
            }

            GroupBox(L10n.t("Message")) {
                ScrollView {
                    Text(entry.message)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120)
            }

            GroupBox(L10n.t("Raw JSON")) {
                ScrollView {
                    Text(prettyRawJSON)
                        .textSelection(.enabled)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 140)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .textSelection(.enabled)
        }
    }

    private var prettyRawJSON: String {
        guard let data = entry.rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return entry.rawLine
        }
        return pretty
    }
}

private struct SimulatorLogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .json, UTType(filenameExtension: "log") ?? .plainText]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension SimulatorLogLevel {
    var displayColor: Color {
        switch self {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .default:
            return .primary
        case .error:
            return .orange
        case .fault:
            return .red
        case .unknown:
            return .secondary
        }
    }

    var messageColor: Color {
        switch self {
        case .debug:
            return .secondary
        case .error:
            return .orange
        case .fault:
            return .red
        case .info, .default, .unknown:
            return .primary
        }
    }
}
