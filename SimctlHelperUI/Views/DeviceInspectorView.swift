import SwiftUI

struct DeviceInspectorView: View {
    let selectedDevice: DeviceRecord?
    let onOpenControls: () -> Void
    let onToggleBoot: () -> Void
    let onClone: () -> Void
    let onDelete: () -> Void
    let onCopyUDID: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selectedDevice {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("Device Details"))
                        .font(.headline)

                    InfoRow(label: L10n.t("Name"), value: selectedDevice.name)
                    InfoRow(label: L10n.t("State"), value: selectedDevice.state.displayName)
                    InfoRow(label: L10n.t("Availability"), value: selectedDevice.availabilityText)
                    InfoRow(label: L10n.t("Device Type"), value: selectedDevice.deviceTypeName)
                    InfoRow(label: L10n.t("Runtime"), value: selectedDevice.runtimeName)
                    InfoRow(label: "UDID", value: selectedDevice.udid)
                        .font(.system(.caption, design: .monospaced))
                }

                Button(L10n.t("Open Controls")) {
                    onOpenControls()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu(L10n.t("Actions")) {
                    Button(selectedDevice.isBooted ? L10n.t("Shutdown") : L10n.t("Boot")) {
                        onToggleBoot()
                    }

                    Button(L10n.t("Clone Device")) {
                        onClone()
                    }

                    Button(L10n.t("Copy UDID")) {
                        onCopyUDID()
                    }

                    Divider()

                    Button(L10n.t("Delete Device"), role: .destructive) {
                        onDelete()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("No device selected"))
                        .font(.headline)
                    Text(L10n.t("Select a simulator to inspect details and open location controls."))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
