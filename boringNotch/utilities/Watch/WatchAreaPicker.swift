// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), the geometry mode of
// ScreenshotSelectionController.swift. Adapted for boring.notch: a small, transparent overlay
// of its own (no frozen screenshot, loupe, capture tools or remembered region). It never touches
// the notch window, so cancelling it leaves the notch as it was.

import AppKit
import Carbon.HIToolbox

/// What the person chose over the overlay.
enum WatchPick {
    /// A click on a window: all of it.
    case window(CGWindowID)
    /// A dragged area. `globalRect` is in the window server's top-left coordinates;
    /// `displayRect` is the same area in points from its display's top-left corner.
    case area(globalRect: CGRect, displayID: CGDirectDisplayID, displayRect: CGRect, scale: CGFloat)
}

/// One borderless panel per screen, above everything (the notch included), where the person
/// drags over what to watch or clicks a window. Esc or a right click cancels.
@MainActor
final class WatchAreaPicker {
    private(set) static var isOnScreen = false

    private var panels: [WatchPickerPanel] = []
    private var keyMonitor: Any?
    private var completion: ((WatchPick?) -> Void)?
    private var finished = false

    func begin(completion: @escaping (WatchPick?) -> Void) {
        guard !Self.isOnScreen else { completion(nil); return }
        Self.isOnScreen = true
        self.completion = completion
        let windows = WatchCapture.pickableWindows()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens where screen.watchDisplayID != 0 {
            // Windows in this screen's own coordinates, front to back.
            let local: [(id: CGWindowID, rect: CGRect)] = windows.compactMap { window in
                let cocoa = CGRect(x: window.bounds.minX, y: mainHeight - window.bounds.maxY,
                                   width: window.bounds.width, height: window.bounds.height)
                guard cocoa.intersects(screen.frame) else { return nil }
                return (window.id, cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            }
            let panel = WatchPickerPanel(screen: screen, windows: local, picker: self)
            panels.append(panel)
        }
        guard !panels.isEmpty else { finish(nil); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window is WatchPickerPanel else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.finish(nil); return nil }
            return event
        }
        panels.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    func cancel() {
        finish(nil)
    }

    fileprivate func pickWindow(_ id: CGWindowID) {
        finish(.window(id))
    }

    fileprivate func pickArea(_ localRect: CGRect, on screen: NSScreen) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let global = CGRect(x: cocoa.minX, y: mainHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
        let display = CGRect(x: localRect.minX, y: screen.frame.height - localRect.maxY,
                             width: localRect.width, height: localRect.height)
        finish(.area(globalRect: global, displayID: screen.watchDisplayID, displayRect: display,
                     scale: screen.backingScaleFactor))
    }

    private func finish(_ pick: WatchPick?) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels = []
        Self.isOnScreen = false
        NSCursor.arrow.set()
        let completion = self.completion
        self.completion = nil
        completion?(pick)
    }
}

private final class WatchPickerPanel: NSPanel {
    init(screen: NSScreen, windows: [(id: CGWindowID, rect: CGRect)], picker: WatchAreaPicker) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        let view = WatchPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.windows = windows
        view.onWindow = { [weak picker] id in picker?.pickWindow(id) }
        view.onArea = { [weak picker, weak screen] rect in
            guard let screen else { return }
            picker?.pickArea(rect, on: screen)
        }
        view.onCancel = { [weak picker] in picker?.cancel() }
        contentView = view
        initialFirstResponder = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WatchPickerView: NSView {
    var windows: [(id: CGWindowID, rect: CGRect)] = []
    var onWindow: ((CGWindowID) -> Void)?
    var onArea: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var hovered: CGRect?
    private var hoveredID: CGWindowID?
    private var pointerInside = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                 .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        window?.makeKey()
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hovered = nil
        hoveredID = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
                          width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y))
        dragRect = rect.intersection(bounds)
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragRect = nil; needsDisplay = true }
        if let rect = dragRect, rect.width >= 8, rect.height >= 8 {
            onArea?(rect.integral)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let window = windows.first(where: { $0.rect.contains(point) }) {
            onWindow?(window.id)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func updateHover(_ point: CGPoint) {
        guard dragStart == nil else { return }
        let window = windows.first { $0.rect.contains(point) }
        guard window?.id != hoveredID else { return }
        hoveredID = window?.id
        hovered = window?.rect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        let tint = NSColor.systemPurple
        if let dragRect {
            NSGraphicsContext.current?.compositingOperation = .clear
            dragRect.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            tint.withAlphaComponent(0.12).setFill()
            dragRect.fill()
            let border = NSBezierPath(rect: dragRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            tint.setStroke()
            border.stroke()
        } else if let hovered {
            let path = NSBezierPath(roundedRect: hovered.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            tint.withAlphaComponent(0.14).setFill()
            path.fill()
            path.lineWidth = 2
            tint.setStroke()
            path.stroke()
        }
        if pointerInside || window?.isKeyWindow == true { drawHint() }
    }

    private func drawHint() {
        let text = "Drag over what to watch, or click a window. Esc cancels." as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 120,
                         width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attributes)
    }
}
