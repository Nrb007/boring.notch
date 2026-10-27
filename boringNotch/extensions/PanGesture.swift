//
//  PanGesture.swift
//  boringNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

enum PanDirection {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }

    func signed(from translation: CGSize) -> CGFloat { (isHorizontal ? translation.width : translation.height) * sign }
    func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat { (isHorizontal ? deltaX : deltaY) * sign }
}

extension View {
    func panGesture(direction: PanDirection, threshold: CGFloat = 4, action: @escaping (CGFloat, NSEvent.Phase) -> Void) -> some View {
        self
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let s = direction.signed(from: value.translation)
                        guard s > 0, s.magnitude >= threshold else { return }
                        action(s.magnitude, .changed)
                    }
                    .onEnded { _ in action(0, .ended) }
            )
            .background(ScrollMonitor(direction: direction, threshold: threshold, action: action))
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { 
        Coordinator(direction: direction, threshold: threshold, action: action) 
    }

    @MainActor final class Coordinator: NSObject {
        private let direction: PanDirection
        private let threshold: CGFloat
        private let action: (CGFloat, NSEvent.Phase) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var active = false
            private var endTask: Task<Void, Never>?
        private let noiseThreshold: CGFloat = 0.2

        init(direction: PanDirection, threshold: CGFloat, action: @escaping (CGFloat, NSEvent.Phase) -> Void) {
            self.direction = direction
            self.threshold = threshold
            self.action = action
        }

        private func scheduleEndTimeout() {
            // Cancel any existing scheduled end and schedule a new one.
            endTask?.cancel()
            endTask = Task { @MainActor in
                // If no new scroll event arrives within this window, consider the gesture ended.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
            }
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self = self, event.window === view?.window else { return event }
                self.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            accumulated = 0
            active = false
            endTask?.cancel()
            endTask = nil
        }

        private func handleScroll(_ event: NSEvent) {
            if event.phase == .ended || event.momentumPhase == .ended {
                if active {
                    action(accumulated.magnitude, .ended)
                } else {
                    action(0, .ended)
                }
                active = false
                accumulated = 0
                return
            }

            // Only consider scroll events that are primarily along the configured axis.
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            // Require the movement along the gesture axis to be at least 1.5x the orthogonal axis.
            let axisDominanceFactor: CGFloat = 1.5
            let isAxisDominant: Bool = direction.isHorizontal ? (absDX >= axisDominanceFactor * absDY) : (absDY >= axisDominanceFactor * absDX)
            guard isAxisDominant else { return }

            // Scale non-precise (mouse wheel) scrolling deltas so they feel similar to
            // trackpad gestures.
            let raw = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let s = raw * scale
            guard s.magnitude > noiseThreshold else { return }
            accumulated = s > 0 ? accumulated + s : 0

            if !active && accumulated >= threshold {
                active = true
                action(accumulated.magnitude, .began)
            } else if active {
                action(accumulated.magnitude, .changed)
            }
            // Schedule a timeout to end the gesture if no further scroll events arrive.
            scheduleEndTimeout()
        }
    }
}

// MARK: - Two-finger swipes

extension View {
    /// Fires once per two-finger horizontal trackpad swipe over this view. Overlapping swipe regions
    /// don't double-fire: only the smallest one under the pointer handles the swipe, and swipes over
    /// content that scrolls horizontally (e.g. the calendar's date strip) are left to that content.
    func onHorizontalSwipe(threshold: CGFloat = 24, perform action: @escaping (PanDirection) -> Void) -> some View {
        background(SwipeMonitor(axis: .horizontal, threshold: threshold, action: action))
    }

    /// The vertical counterpart: reports .down or .up by finger direction, and leaves swipes over
    /// content that scrolls vertically (a long list or note) to that content.
    func onVerticalSwipe(threshold: CGFloat = 40, perform action: @escaping (PanDirection) -> Void) -> some View {
        background(SwipeMonitor(axis: .vertical, threshold: threshold, action: action))
    }
}

private struct SwipeMonitor: NSViewRepresentable {
    let axis: Axis
    let threshold: CGFloat
    let action: (PanDirection) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.action = action }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    func makeCoordinator() -> Coordinator { Coordinator(axis: axis, threshold: threshold, action: action) }

    @MainActor final class Coordinator: NSObject {
        private static var registered: [Coordinator] = []

        private let axis: Axis
        private let threshold: CGFloat
        var action: (PanDirection) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        init(axis: Axis, threshold: CGFloat, action: @escaping (PanDirection) -> Void) {
            self.axis = axis
            self.threshold = threshold
            self.action = action
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            self.view = view
            Self.registered.append(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            Self.registered.removeAll { $0 === self }
        }

        private func handleScroll(_ event: NSEvent) {
            guard let view, event.window === view.window, event.hasPreciseScrollingDeltas else { return }

            if event.phase == .began || event.phase == .mayBegin {
                accumulated = 0
                fired = false
            }
            // Trackpad finger movement only; ignore inertia after the fingers lift
            guard !event.phase.isEmpty, event.momentumPhase.isEmpty, !fired else { return }

            let along = axis == .horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            let across = axis == .horizontal ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(along) >= 1.5 * abs(across), owns(event.locationInWindow) else { return }

            // Track the physical finger direction regardless of the natural scrolling setting
            accumulated += event.isDirectionInvertedFromDevice ? along : -along
            if accumulated.magnitude >= threshold {
                fired = true
                switch axis {
                case .horizontal: action(accumulated < 0 ? .left : .right)
                case .vertical: action(accumulated > 0 ? .down : .up)
                }
            }
        }

        private func frameInWindow() -> CGRect? {
            guard let view, view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil)
        }

        private func owns(_ point: CGPoint) -> Bool {
            guard let frame = frameInWindow(), frame.contains(point) else { return false }
            let area = frame.width * frame.height
            let smallerRegionContainsPoint = Self.registered.contains { other in
                guard other !== self, other.axis == axis, other.view?.window === view?.window,
                      let otherFrame = other.frameInWindow() else { return false }
                return otherFrame.contains(point) && otherFrame.width * otherFrame.height < area
            }
            return !smallerRegionContainsPoint && !isOverScrollableContent(point)
        }

        private func isOverScrollableContent(_ point: CGPoint) -> Bool {
            var hit = view?.window?.contentView?.hitTest(point)
            while let current = hit {
                if current is NSSlider { return true }
                // Sideways swipes over text would fight with selecting it; vertical ones only matter
                // when the text is long enough to scroll, which the scroll view check below catches
                if axis == .horizontal, current is NSTextView { return true }
                if let scrollView = current as? NSScrollView, let document = scrollView.documentView {
                    let overflows = axis == .horizontal
                        ? document.frame.width > scrollView.contentSize.width + 1
                        : document.frame.height > scrollView.contentSize.height + 1
                    if overflows { return true }
                }
                hit = current.superview
            }
            return false
        }
    }
}
