import SwiftUI
import AppKit

@MainActor
enum LocationPlayerWindowCoordinator {
    static let windowGroupID = "location-player"
    private static let identifierPrefix = "location-player:"
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("main-window")

    static func focusWindow(for udid: String?) -> Bool {
        let targetIdentifier = windowIdentifier(for: udid)
        guard let window = NSApp.windows.first(where: { $0.identifier == targetIdentifier }) else {
            return false
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFront(nil)
        return true
    }

    static func openWindowWithoutStealingFocus(for udid: String?, openWindow: OpenWindowAction) {
        let previousKeyWindow = NSApp.keyWindow

        if focusWindow(for: udid) {
            restoreFocus(to: previousKeyWindow)
            return
        }

        if let udid {
            openWindow(id: windowGroupID, value: udid)
        } else {
            openWindow(id: windowGroupID)
        }

        restoreFocus(to: previousKeyWindow)
    }

    static func assignMainWindowIdentifier(to window: NSWindow) {
        window.identifier = mainWindowIdentifier
    }

    static func assignIdentifier(to window: NSWindow, udid: String?) {
        window.identifier = windowIdentifier(for: udid)
    }

    static func reassignIdentifier(from oldUDID: String?, to newUDID: String?) {
        let oldIdentifier = windowIdentifier(for: oldUDID)
        guard let window = NSApp.windows.first(where: { $0.identifier == oldIdentifier }) else {
            return
        }
        assignIdentifier(to: window, udid: newUDID)
    }

    private static func restoreFocus(to window: NSWindow?) {
        guard let window, window.isVisible else { return }
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func windowIdentifier(for udid: String?) -> NSUserInterfaceItemIdentifier {
        let resolvedUDID = (udid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return NSUserInterfaceItemIdentifier(identifierPrefix + resolvedUDID)
    }
}

struct WindowObserverView: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onResolveWindow = onResolveWindow
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        nsView.onResolveWindow = onResolveWindow
        nsView.resolveWindowIfNeeded()
    }
}

final class WindowObserverNSView: NSView {
    var onResolveWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindowIfNeeded()
    }

    func resolveWindowIfNeeded() {
        guard let window else { return }
        onResolveWindow?(window)
    }
}
