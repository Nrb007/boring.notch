// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchWatchView.swift,
// with its English strings from NotchWatchStrings.swift. Adapted for boring.notch: the island's
// top row became the utility header, the area card and the rule sit side by side to fit the
// notch's short page, and Screen Recording is asked for on the page itself.

import AppKit
import Defaults
import SwiftUI

private let watchTint = Color.purple

struct WatchUtilityView: View {
    @ObservedObject private var watch = WatchService.shared
    @State private var hasAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .watch, title: headerTitle) {
                if watch.target != nil {
                    iconButton("viewfinder", title: "Choose another area") { watch.chooseArea() }
                    iconButton("xmark", title: "Stop watching") { watch.stop() }
                }
            }
            Group {
                if watch.target != nil, !watch.permissionMissing {
                    WatchActiveView()
                } else if !hasAccess || watch.permissionMissing {
                    WatchPermissionView()
                } else {
                    WatchSetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(watchTint)
        .onAppear { watch.pageVisible = true }
        .onDisappear { watch.pageVisible = false }
        // Follows a grant made in System Settings while the page is shown.
        .task {
            while !Task.isCancelled {
                let granted = CGPreflightScreenCaptureAccess()
                if granted != hasAccess { hasAccess = granted }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var headerTitle: String? {
        guard let target = watch.target else { return nil }
        guard let window = target.windowTitle, window != target.appName else { return target.appName }
        return "\(target.appName) · \(window)"
    }

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: Setup and permission

private struct WatchGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .light))
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 52, height: 52)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct WatchPillButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .foregroundStyle(prominent ? watchTint : .white.opacity(0.85))
                .background(prominent ? watchTint.opacity(0.22) : Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Before anything is watched: what the page does, and the one step that starts it.
private struct WatchSetupView: View {
    @ObservedObject private var watch = WatchService.shared

    var body: some View {
        HStack(spacing: 14) {
            WatchGlyph(symbol: "eye")
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose any part of a window, like a progress bar, a build status or a score. "
                     + "The notch reads it for you and tells you when it changes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                WatchPillButton(title: watch.isChoosing ? "Choosing…" : "Choose Area") { watch.chooseArea() }
                    .disabled(watch.isChoosing)
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }
}

/// Screen Recording is off: why Watch needs it, and the two ways to turn it on.
private struct WatchPermissionView: View {
    var body: some View {
        HStack(spacing: 14) {
            WatchGlyph(symbol: "lock")
            VStack(alignment: .leading, spacing: 8) {
                Text("Watch reads the area you choose on your Mac, so it needs Screen Recording. "
                     + "Nothing leaves your Mac. If you just allowed it, quit and reopen boring.notch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    WatchPillButton(title: "Allow Screen Recording") { CGRequestScreenCaptureAccess() }
                    WatchPillButton(title: "Open System Settings", prominent: false) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: Watching

/// The live area on the left; its reading, the rule and what happened on the right.
private struct WatchActiveView: View {
    @ObservedObject private var watch = WatchService.shared

    private var lines: [String] { NotchWatchSupport.lines(in: watch.text) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            previewCard
                .frame(width: 190)
            VStack(alignment: .leading, spacing: 5) {
                readingRow
                let full = watch.text.replacingOccurrences(of: "\n", with: " ")
                if !full.isEmpty, full != watch.headline {
                    Text(full)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                WatchRuleRow()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 2)
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.07))
            if let image = watch.preview {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(5)
                    .opacity(watch.state == .hidden ? 0.35 : 1)
            } else if watch.state != .hidden {
                ProgressView().controlSize(.small)
            }
            if watch.state == .hidden {
                Label("Hidden. Watching continues when it returns.", systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
            }
        }
    }

    @ViewBuilder private var readingRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if case .finished(let outcome) = watch.state {
                Image(systemName: outcome == .closed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(outcome == .closed ? Color.gray : Color.green)
                Text(outcome.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else if lines.isEmpty {
                Text(watch.preview == nil ? "Reading…" : "No text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                headlineMenu
            }
            Spacer(minLength: 0)
        }
    }

    /// What the closed notch shows, picked automatically or chosen line by line when the
    /// automatic pick lands on the wrong words.
    private var headlineMenu: some View {
        Menu {
            Section("Show in the closed notch") {
                choice("Automatic", selected: watch.headlineLine == nil) { watch.setHeadlineLine(nil) }
                ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { index, line in
                    choice(line, selected: watch.headlineLine == index) { watch.setHeadlineLine(index) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(watch.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show in the closed notch")
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    @ViewBuilder private var footer: some View {
        if case .finished = watch.state {
            HStack(spacing: 8) {
                if watch.canWatchAgain {
                    WatchPillButton(title: "Watch Again") { watch.watchAgain() }
                }
                WatchPillButton(title: "Choose Another Area", prominent: !watch.canWatchAgain) { watch.chooseArea() }
                Spacer(minLength: 0)
            }
        } else if let started = watch.startedAt {
            Text("Watching since \(started.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }
}

/// When to alert. A word or a number applies once Return is pressed or the field is left, so
/// typing never ends the watch halfway. After a watch ends the rule can still change, for the
/// next Watch Again.
private struct WatchRuleRow: View {
    @ObservedObject private var watch = WatchService.shared
    @State private var draftText = ""
    @State private var draftNumber = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("Tell me")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Menu {
                ForEach(NotchWatchCondition.allCases) { condition in
                    Button { watch.setCondition(condition) } label: {
                        Label(condition.title, systemImage: condition.symbol)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: watch.condition.symbol)
                    Text(watch.condition.title)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(watchTint)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if watch.condition == .contains || watch.condition == .reaches {
                let number = watch.condition == .reaches
                WatchRuleField(placeholder: number ? "Number, like 100" : "Text, like Done",
                               text: number ? $draftNumber : $draftText,
                               onCommit: apply)
                    .frame(maxWidth: 150)
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if watch.condition == .settles {
                Text("After a change, still for 30 s")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            draftText = watch.matchText
            draftNumber = watch.matchNumber.map { NotchWatchSupport.formatted($0, locale: .autoupdatingCurrent) } ?? ""
        }
    }

    private func apply() {
        if watch.condition == .reaches { watch.setMatchNumber(draftNumber) } else { watch.setMatchText(draftText) }
    }
}

/// A one-line field that works in the notch's non-key panel: a click asks for keyboard focus,
/// Return or leaving the field applies it and gives the focus back.
private struct WatchRuleField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            .font: NSFont.systemFont(ofSize: 12),
        ])
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 12),
            ])
        }
    }

    static func dismantleNSView(_ field: FocusingTextField, coordinator: Coordinator) {
        NotchKeyboardFocus.release(from: field.window)
    }

    final class FocusingTextField: NSTextField {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            NotchKeyboardFocus.request(for: self)
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WatchRuleField

        init(_ parent: WatchRuleField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            MainActor.assumeIsolated { UtilitiesState.shared.noteTyping() }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
            MainActor.assumeIsolated {
                NotchKeyboardFocus.release(from: field.window)
                UtilitiesState.shared.releaseHold()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

// MARK: Settings

struct WatchSettingsSection: View {
    @Default(.watchSoundEnabled) private var watchSoundEnabled

    var body: some View {
        Toggle("Play a sound when the rule is met", isOn: $watchSoundEnabled)
        Text("Watch reads the area you choose on your Mac and needs Screen Recording. Nothing leaves your Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
