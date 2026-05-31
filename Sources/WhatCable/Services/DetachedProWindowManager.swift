import AppKit
import SwiftUI
import WhatCableAppKit

/// Hosts a Pro screen in its own standalone window when the user taps
/// "detach" in the popover. In-place rendering stays the default; this is
/// an opt-in, user-triggered escape hatch so a diagnostics screen can
/// stay open while cables are plugged and unplugged. It reuses the exact
/// same view `PluginRegistry` builds for in-place rendering, so detached
/// and in-place content are identical. This is NOT the old auto-spawning
/// behaviour: a window only appears when the user asks for it.
@MainActor
final class DetachedProWindowManager: NSObject, NSWindowDelegate {
    static let shared = DetachedProWindowManager()
    private override init() { super.init() }

    private var windows: [String: NSWindow] = [:]

    /// Open the route's Pro screen in a standalone window, or focus the
    /// existing one if it's already detached.
    func open(route: ProScreenRoute) {
        let key = Self.key(for: route)
        if let existing = windows[key] {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = PluginRegistry.shared.proScreen(id: route.id, portCard: route.portCard) else {
            return
        }
        let host = NSHostingController(rootView: screen)
        let window = NSWindow(contentViewController: host)
        window.title = Self.title(for: route)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 680))
        window.minSize = NSSize(width: 520, height: 420)
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// If a window for this route is already detached, focus it and
    /// return true so the caller can skip rendering it in-place too.
    func focusIfOpen(route: ProScreenRoute) -> Bool {
        guard let existing = windows[Self.key(for: route)] else { return false }
        NSApp.activate()
        existing.makeKeyAndOrderFront(nil)
        return true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard let w = notification.object as? NSWindow,
                  let id = w.identifier?.rawValue else { return }
            windows[id] = nil
        }
    }

    /// Cable Diagnostics is per-port, so its key includes the port to
    /// allow one detached window per port. The other screens are global.
    private static func key(for route: ProScreenRoute) -> String {
        var k = "uk.whatcable.detached.\(route.id)"
        if let portKey = route.portCard?.portKey {
            k += ".\(portKey)"
        }
        return k
    }

    private static func title(for route: ProScreenRoute) -> String {
        switch route.id {
        case "pro.power-monitor":
            return String(localized: "Power Monitor", bundle: _appLocalizedBundle)
        case "pro.negotiation":
            return String(localized: "Negotiation Diagnostics", bundle: _appLocalizedBundle)
        case "pro.cable-diagnostics":
            let num = route.portCard?.portNumber ?? 0
            if let type = route.portCard?.portTypeDescription {
                return String(localized: "\(type) Port \(num) Diagnostics", bundle: _appLocalizedBundle)
            }
            return String(localized: "Cable Diagnostics", bundle: _appLocalizedBundle)
        case "pro.overview":
            return String(localized: "WhatCable Pro", bundle: _appLocalizedBundle)
        default:
            return "WhatCable"
        }
    }
}
