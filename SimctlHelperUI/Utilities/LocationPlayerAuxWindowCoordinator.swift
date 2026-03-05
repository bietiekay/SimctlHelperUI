import SwiftUI
import AppKit

@MainActor
enum LocationPlayerAuxWindowKind: String {
    case mapEditor
    case gpxPreview
    case importSelection

    var autosaveName: String {
        "LocationPlayerAuxWindow.\(rawValue)"
    }

    var defaultSize: NSSize {
        switch self {
        case .mapEditor:
            return NSSize(width: 980, height: 720)
        case .gpxPreview:
            return NSSize(width: 960, height: 760)
        case .importSelection:
            return NSSize(width: 620, height: 560)
        }
    }

    var minSize: NSSize {
        switch self {
        case .mapEditor:
            return NSSize(width: 760, height: 560)
        case .gpxPreview:
            return NSSize(width: 820, height: 700)
        case .importSelection:
            return NSSize(width: 520, height: 520)
        }
    }
}

@MainActor
final class LocationPlayerAuxWindowCoordinator {
    static let shared = LocationPlayerAuxWindowCoordinator()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: AuxWindowDelegate] = [:]

    private init() {}

    static func windowKey(
        ownerWindowIdentifier: String?,
        kind: LocationPlayerAuxWindowKind
    ) -> String {
        let owner = (ownerWindowIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? kind.rawValue : "\(owner)|\(kind.rawValue)"
    }

    func present<Content: View>(
        kind: LocationPlayerAuxWindowKind,
        ownerWindowIdentifier: String?,
        title: String,
        parentWindow: NSWindow?,
        @ViewBuilder content: @escaping (@escaping () -> Void) -> Content
    ) {
        let key = Self.windowKey(ownerWindowIdentifier: ownerWindowIdentifier, kind: kind)
        let window = ensureWindow(for: key, kind: kind, title: title, parentWindow: parentWindow)
        let closeAction: () -> Void = { [weak window] in
            window?.close()
        }

        let rootView = AnyView(content(closeAction))
        window.contentViewController = NSHostingController(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow(
        for key: String,
        kind: LocationPlayerAuxWindowKind,
        title: String,
        parentWindow: NSWindow?
    ) -> NSWindow {
        if let existing = windows[key] {
            existing.title = title
            existing.minSize = kind.minSize
            enforceMinimumSize(existing, minimum: kind.minSize)
            if let parentWindow {
                parentWindow.addChildWindow(existing, ordered: .above)
            }
            return existing
        }

        let rect = NSRect(origin: .zero, size: kind.defaultSize)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        window.minSize = kind.minSize
        window.setFrameAutosaveName(kind.autosaveName)
        if !window.setFrameUsingName(kind.autosaveName) {
            window.center()
        }
        enforceMinimumSize(window, minimum: kind.minSize)

        if let parentWindow {
            parentWindow.addChildWindow(window, ordered: .above)
        }

        let delegate = AuxWindowDelegate { [weak self] in
            self?.windows.removeValue(forKey: key)
            self?.delegates.removeValue(forKey: key)
        }
        window.delegate = delegate
        windows[key] = window
        delegates[key] = delegate
        return window
    }

    private func enforceMinimumSize(_ window: NSWindow, minimum: NSSize) {
        let frame = window.frame
        let clampedSize = NSSize(
            width: max(frame.size.width, minimum.width),
            height: max(frame.size.height, minimum.height)
        )

        guard clampedSize != frame.size else { return }

        let clampedOrigin = NSPoint(
            x: frame.origin.x,
            y: frame.origin.y + (frame.size.height - clampedSize.height)
        )
        let clampedFrame = NSRect(origin: clampedOrigin, size: clampedSize)
        window.setFrame(clampedFrame, display: true)
    }
}

private final class AuxWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
