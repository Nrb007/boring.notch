//
//  ClipboardSearchField.swift
//  boringNotch
//
//  The clipboard page's search field. An AppKit text field takes keyboard focus in the notch's
//  non-activating panel more reliably than a SwiftUI one; it asks for focus while it's on screen
//  (NotchKeyboardFocus), keeps the notch open while typing, and hands the arrow keys, Return and
//  Escape to the list, the way Vorssaint's notch clipboard page reads them before its field does.
//

import AppKit
import SwiftUI

struct ClipboardSearchField: NSViewRepresentable {
    enum Command {
        case moveUp
        case moveDown
        case activate
        case cancel
    }

    @Binding var text: String
    var placeholder: String
    /// True when the page used the key.
    var onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstMouseTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 12)])
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        DispatchQueue.main.async { context.coordinator.focus() }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        NotchKeyboardFocus.release(from: field.window)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ClipboardSearchField
        weak var field: NSTextField?

        init(_ parent: ClipboardSearchField) {
            self.parent = parent
        }

        @MainActor
        func focus() {
            guard let field, let window = field.window else { return }
            NotchKeyboardFocus.request(for: field)
            if window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
            MainActor.assumeIsolated { UtilitiesState.shared.noteTyping() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: Command
            switch selector {
            case #selector(NSResponder.moveUp(_:)): command = .moveUp
            case #selector(NSResponder.moveDown(_:)): command = .moveDown
            case #selector(NSResponder.insertNewline(_:)): command = .activate
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            default:
                MainActor.assumeIsolated { UtilitiesState.shared.noteTyping() }
                return false
            }
            MainActor.assumeIsolated { UtilitiesState.shared.noteTyping() }
            // The input method keeps Return, the arrows and Escape while it composes.
            guard !textView.hasMarkedText() else { return false }
            return parent.onCommand(command)
        }
    }
}

/// The notch panel isn't key until a page asks; a click must still reach the field.
private final class FirstMouseTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NotchKeyboardFocus.request(for: self)
        super.mouseDown(with: event)
    }
}

/// A clipboard thumbnail that never decodes on the main thread. A cached one
/// shows at once; otherwise the row keeps the image's shape with a quiet
/// placeholder while the decode runs in the background.
/// Ported from Vorssaint's ClipboardThumbnailImage.swift (GPL-3.0-or-later,
/// Copyright (C) 2026 Vorssaint).
struct ClipboardThumbnailImage: View {
    let source: ClipboardImageStore.ThumbnailSource
    var aspectRatio: CGFloat?

    @State private var loaded: (source: ClipboardImageStore.ThumbnailSource, image: NSImage?)?

    private var image: NSImage? {
        if let loaded, loaded.source == source { return loaded.image }
        return ClipboardImageStore.cachedThumbnail(source)
    }

    private var failed: Bool {
        guard let loaded, loaded.source == source else { return false }
        return loaded.image == nil
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .aspectRatio(aspectRatio ?? 1, contentMode: .fit)
                    .overlay {
                        if failed {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
            }
        }
        .task(id: source) {
            // Kept in state even on a cache hit: the cache may evict it while
            // the row is still on screen.
            let image = await ClipboardImageStore.loadThumbnail(source)
            guard !Task.isCancelled else { return }
            loaded = (source, image)
        }
    }
}
