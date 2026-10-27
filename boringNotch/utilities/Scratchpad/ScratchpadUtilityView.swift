//
//  ScratchpadUtilityView.swift
//  boringNotch
//
//  The scratchpad page: tabs for each note in the header, the selected note's text below.
//  Based on Vorssaint's NotchScratchpadView (GPL-3.0-or-later, Copyright (C) 2026 Vorssaint).
//

import AppKit
import Defaults
import SwiftUI

struct ScratchpadUtilityView: View {
    @ObservedObject private var pad = ScratchpadService.shared
    @Default(.scratchpadTextSize) private var textSize
    @State private var loadFailed = false
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var confirmingDeleteID: UUID?

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .scratchpad) {
                if !loadFailed { tabs }
            }
            if loadFailed {
                Label("Couldn't open the scratchpad", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if pad.saveFailed {
                    Label("Couldn't save. Your text is kept until it can be.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                editor
            }
        }
        .onAppear { loadFailed = !pad.load() }
        .onDisappear { pad.commitEdits() }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            ScratchpadEditor(text: $pad.text, fontSize: CGFloat(textSize), focusTrigger: pad.selectedPadID)
            if pad.text.isEmpty {
                Text("Jot something down…")
                    .font(.system(size: CGFloat(textSize)))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, ScratchpadEditor.inset.width + 5)
                    .padding(.top, ScratchpadEditor.inset.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Tabs

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(pad.pads) { note in
                    tab(note)
                }
                if pad.canAddPad {
                    Button(action: pad.addPad) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New note")
                }
            }
        }
        .frame(maxWidth: 420)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func tab(_ note: ScratchpadPad) -> some View {
        let selected = note.id == pad.selectedPadID
        HStack(spacing: 4) {
            if renamingID == note.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 80)
                    .onSubmit { finishRename(note.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(note.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
            }
            if selected && renamingID != note.id {
                deleteButton(note)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture(count: 2) {
            renameText = note.name
            renamingID = note.id
        }
        .onTapGesture {
            if renamingID != nil, renamingID != note.id { renamingID = nil }
            confirmingDeleteID = nil
            pad.select(note.id)
        }
        .help("Double-click to rename")
    }

    /// Deleting a note with text takes a second click, since there's no undo for it.
    private func deleteButton(_ note: ScratchpadPad) -> some View {
        let confirming = confirmingDeleteID == note.id
        return Button {
            if note.text.isEmpty || confirming {
                confirmingDeleteID = nil
                pad.remove(note.id)
            } else {
                confirmingDeleteID = note.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if confirmingDeleteID == note.id { confirmingDeleteID = nil }
                }
            }
        } label: {
            Group {
                if confirming {
                    Text(pad.pads.count > 1 ? "Delete?" : "Clear?")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pad.pads.count > 1 ? "Delete note" : "Clear note")
    }

    private func finishRename(_ id: UUID) {
        pad.rename(id, to: renameText)
        renamingID = nil
    }
}

/// A plain-text editor for the notch. It asks the notch window for keyboard focus while it's on
/// screen, and continues Markdown-style lists on Return.
struct ScratchpadEditor: NSViewRepresentable {
    static let inset = NSSize(width: 6, height: 6)

    @Binding var text: String
    let fontSize: CGFloat
    /// Changing this (e.g. switching notes) puts the caret back in the text.
    let focusTrigger: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = Self.inset
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = .systemFont(ofSize: fontSize)
        textView.string = text
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.focus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { context.coordinator.focus() }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotchKeyboardFocus.release(from: scrollView.window)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadEditor
        weak var textView: NSTextView?
        var lastFocusTrigger: UUID?

        init(_ parent: ScratchpadEditor) {
            self.parent = parent
            self.lastFocusTrigger = parent.focusTrigger
        }

        @MainActor
        func focus() {
            guard let textView, textView.window != nil else { return }
            NotchKeyboardFocus.request(for: textView)
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let edit = ScratchpadSupport.lineBreakEdit(in: textView.string, selection: textView.selectedRange())
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
            return true
        }
    }
}
