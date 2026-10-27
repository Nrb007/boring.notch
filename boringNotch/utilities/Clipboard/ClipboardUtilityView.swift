// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchClipboardView.swift,
// adapted for boring.notch: the island's cards become compact rows that fit the Utilities page,
// with search, the pinned filter and "Clear unpinned" in the page header. A click pastes into the
// app in front when the notch may type (Accessibility), and copies otherwise. Vorssaint's card
// sizes, hover-to-expand, move up/down, ⌘1–⌘9, color swatches and image editing aren't ported.

import AppKit
import Defaults
import SwiftUI

struct ClipboardUtilityView: View {
    @ObservedObject private var history = ClipboardHistoryService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var query = ""
    @State private var pinnedOnly = false
    /// The row the arrow keys chose; Return uses it the way a click would.
    @State private var highlightedID: UUID?
    @State private var hoveredID: UUID?
    @State private var copiedID: UUID?
    @State private var confirmingClear: [UUID: Date]?
    @State private var canPaste = false

    private static let rowHeight: CGFloat = 26

    private var entries: [ClipboardHistoryEntry] {
        history.filteredEntries(matching: query).filter { !pinnedOnly || $0.isPinned }
    }

    private var searchTokens: [String] {
        ClipboardHistorySearch.searchTokens(for: query)
    }

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .clipboard) {
                headerControls
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            history.activate()
            history.load()
            canPaste = ClipboardHistoryService.canPaste
        }
        .onChange(of: query) { _, _ in
            highlightedID = query.isEmpty ? nil : entries.first?.id
        }
        .onChange(of: pinnedOnly) { _, _ in highlightedID = nil }
        .task(id: copiedID) {
            // The tick confirms one copy; it isn't a lasting state.
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
        .task(id: confirmingClear == nil) {
            guard confirmingClear != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            confirmingClear = nil
        }
    }

    // MARK: Header

    private var headerControls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                ClipboardSearchField(text: $query, placeholder: "Search copied items", onCommand: handle)
                    .frame(height: 16)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 220, height: 22)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            headerButton(symbol: pinnedOnly ? "pin.fill" : "pin",
                         help: pinnedOnly ? "Show all items" : "Show pinned items only",
                         tint: pinnedOnly ? .teal : .white.opacity(0.7)) {
                pinnedOnly.toggle()
            }

            if confirmingClear != nil {
                Button {
                    if let ids = confirmingClear { history.clearRecent(ids) }
                    confirmingClear = nil
                } label: {
                    Text("Clear \(confirmingClear?.count ?? 0)?")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Pinned items stay. This can't be undone.")
            } else {
                headerButton(symbol: "trash", help: "Clear unpinned", tint: .white.opacity(0.7)) {
                    let ids = history.recentEntriesSnapshot
                    if !ids.isEmpty { confirmingClear = ids }
                }
                .disabled(history.recentEntries.isEmpty)
                .opacity(history.recentEntries.isEmpty ? 0.4 : 1)
            }
        }
    }

    private func headerButton(symbol: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if history.loadFailed {
            message("Couldn't open the clipboard history", symbol: "exclamationmark.triangle")
        } else if entries.isEmpty {
            if history.entries.isEmpty {
                message("Nothing copied yet. Copied text, images and files show up here.", symbol: "doc.on.clipboard")
            } else {
                message(pinnedOnly && query.isEmpty ? "No pinned items" : "No results",
                        symbol: pinnedOnly ? "pin" : "magnifyingglass")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        ForEach(entries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                }
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.gray)
            Text(text)
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: ClipboardHistoryEntry) -> some View {
        let active = hoveredID == entry.id
        let highlighted = highlightedID == entry.id
        return HStack(spacing: 8) {
            leadingIcon(entry)
            preview(entry)
                .frame(maxWidth: .infinity, alignment: .leading)
            if active {
                HStack(spacing: 2) {
                    rowButton(symbol: copiedID == entry.id ? "checkmark" : "doc.on.doc",
                              help: copiedID == entry.id ? "Copied" : "Copy") { copy(entry) }
                    rowButton(symbol: entry.isPinned ? "pin.slash" : "pin",
                              help: entry.isPinned ? "Unpin" : "Pin") { history.togglePin(entry) }
                    rowButton(symbol: "trash", help: "Delete item") { remove(entry) }
                }
            } else {
                HStack(spacing: 5) {
                    if copiedID == entry.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.teal)
                    }
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.teal)
                    }
                    Text(entry.copiedAt, style: .time)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(active || highlighted ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.teal.opacity(highlighted ? 0.7 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { activate(entry) }
        .onHover { inside in
            if inside {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        .contextMenu { actions(entry) }
        .help(canPaste ? "Click to paste into the app in front" : "Click to copy")
    }

    private func rowButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func actions(_ entry: ClipboardHistoryEntry) -> some View {
        if canPaste {
            Button("Paste") { paste(entry) }
        }
        Button("Copy") { copy(entry) }
        Divider()
        Button(entry.isPinned ? "Unpin" : "Pin") { history.togglePin(entry) }
        Divider()
        Button("Delete Item", role: .destructive) { remove(entry) }
    }

    /// The app the entry was copied from, the files' own icon, or the kind of entry.
    @ViewBuilder
    private func leadingIcon(_ entry: ClipboardHistoryEntry) -> some View {
        Group {
            if entry.kind == .files, let icon = ClipboardFileIcons.icon(for: entry.filePaths) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else if let id = entry.sourceBundleID, let app = ClipboardAppInfo.app(for: id) {
                Image(nsImage: app.icon).resizable().interpolation(.high)
                    .help("Copied from \(app.name)")
            } else {
                Image(systemName: entry.kind == .image ? "photo" : entry.kind == .files ? "doc" : "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 14, height: 14)
    }

    @ViewBuilder
    private func preview(_ entry: ClipboardHistoryEntry) -> some View {
        switch entry.kind {
        case .image:
            HStack(spacing: 6) {
                if let name = entry.imageFile {
                    ClipboardThumbnailImage(source: .stored(name: name), aspectRatio: entry.imageAspectRatio)
                        .frame(maxWidth: 60, maxHeight: 18, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                ClipboardSearchHighlight.text("\(ClipboardHistoryEntry.imageLabel) · \(entry.imageDimensionsLabel)",
                                              tokens: searchTokens, fontSize: 12)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .help(entry.tooltip)
        case .files:
            HStack(spacing: 6) {
                if entry.filePaths.count == 1, let path = entry.filePaths.first,
                   ClipboardHistoryImageSupport.isImageFileName(path) {
                    ClipboardThumbnailImage(source: .file(path: path))
                        .frame(maxWidth: 60, maxHeight: 18, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                // A count of several files is no text the search reads.
                ClipboardSearchHighlight.text(entry.filePaths.count == 1
                                                  ? (entry.fileNames.first ?? entry.preview)
                                                  : "\(entry.filePaths.count) files",
                                              tokens: entry.filePaths.count == 1 ? searchTokens : [],
                                              fontSize: 12)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(entry.tooltip)
        case .text:
            ClipboardSearchHighlight.text(entry.preview, tokens: searchTokens, fontSize: 12)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .help(entry.tooltip)
        }
    }

    // MARK: Actions

    private func handle(_ command: ClipboardSearchField.Command) -> Bool {
        let ids = entries.map(\.id)
        switch command {
        case .moveUp, .moveDown:
            guard !ids.isEmpty else { return false }
            let step = command == .moveDown ? 1 : -1
            if let current = highlightedID, let index = ids.firstIndex(of: current) {
                highlightedID = ids[min(max(index + step, 0), ids.count - 1)]
            } else {
                highlightedID = step > 0 ? ids.first : ids.last
            }
            return true
        case .activate:
            // With nothing chosen, Return uses the top entry.
            guard let entry = entries.first(where: { $0.id == highlightedID }) ?? entries.first else { return false }
            activate(entry)
            return true
        case .cancel:
            if !query.isEmpty {
                query = ""
                return true
            }
            if highlightedID != nil {
                highlightedID = nil
                return true
            }
            return false
        }
    }

    private func activate(_ entry: ClipboardHistoryEntry) {
        canPaste = ClipboardHistoryService.canPaste
        if canPaste, ClipboardHistoryService.pasteTarget() != nil {
            paste(entry)
        } else {
            copy(entry)
        }
    }

    /// The notch gives the keys back and closes, then the entry is pasted
    /// into the app that was in front.
    private func paste(_ entry: ClipboardHistoryEntry) {
        guard let target = ClipboardHistoryService.pasteTarget() else {
            copy(entry)
            return
        }
        NotchKeyboardFocus.release(from: NSApp.keyWindow)
        UtilitiesState.shared.releaseHold()
        vm.close()
        history.paste(entry, into: target) { _ in }
    }

    private func copy(_ entry: ClipboardHistoryEntry) {
        // A copied recent entry moves to the top, so the second click of a
        // double click would copy whichever entry took its place.
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           event.clickCount > 1 { return }
        history.copy(entry) { copied in
            if copied {
                copiedID = entry.id
            } else {
                NSSound.beep()
            }
        }
    }

    private func remove(_ entry: ClipboardHistoryEntry) {
        if copiedID == entry.id { copiedID = nil }
        if highlightedID == entry.id { highlightedID = nil }
        history.remove(entry)
    }
}

/// The icon Finder shows for an entry's files, looked up once per set of paths.
@MainActor
private enum ClipboardFileIcons {
    private static var cache: [[String]: NSImage] = [:]

    static func icon(for paths: [String]) -> NSImage? {
        if let cached = cache[paths] { return cached }
        guard let icon = NSWorkspace.shared.icon(forFiles: paths) else { return nil }
        if cache.count >= 256 { cache.removeAll() }
        cache[paths] = icon
        return icon
    }
}
