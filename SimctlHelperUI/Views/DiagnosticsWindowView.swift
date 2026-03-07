import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsWindowView: View {
    @State private var debugLogText = RouteDebugLogStore.shared.snapshot()
    @State private var showExporter = false
    @State private var document = DiagnosticsTextDocument(text: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("Diagnostics"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(L10n.f("%d lines", lineCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.t("Use this window for route and command diagnostics without cluttering the primary workflow."))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button(L10n.t("Copy Log")) {
                    copyToClipboard()
                }
                .disabled(debugLogText.isEmpty)

                Button(L10n.t("Clear Log")) {
                    RouteDebugLogStore.shared.clear()
                    refresh()
                }

                Button(L10n.t("Refresh")) {
                    refresh()
                }

                Button(L10n.t("Export Diagnostics")) {
                    document = DiagnosticsTextDocument(text: shareText)
                    showExporter = true
                }

                Spacer()
            }

            ScrollView {
                Text(debugLogText.isEmpty ? L10n.t("No debug entries yet.") : debugLogText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: .routeDebugLogDidChange)) { _ in
            refresh()
        }
        .fileExporter(
            isPresented: $showExporter,
            document: document,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in }
    }

    private var lineCount: Int {
        guard !debugLogText.isEmpty else { return 0 }
        return debugLogText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var shareText: String {
        let header = L10n.t("SimctlHelperUI Diagnostics")
        if debugLogText.isEmpty {
            return "\(header)\n\n\(L10n.t("(empty)"))"
        }
        return "\(header)\n\n\(debugLogText)"
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "simctlhelperui-diagnostics-\(formatter.string(from: Date()))"
    }

    private func refresh() {
        debugLogText = RouteDebugLogStore.shared.snapshot()
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shareText, forType: .string)
    }
}

private struct DiagnosticsTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
