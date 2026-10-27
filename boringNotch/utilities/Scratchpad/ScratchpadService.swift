// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ScratchpadService.swift:
// the document handling and debounced autosave. Vorssaint's floating pad window and global
// shortcut aren't ported; the pad lives in the notch's Utilities tab.

import Combine
import Defaults
import Foundation

/// Saves every edit by itself, shortly after typing pauses and again when the
/// pad leaves the screen, so nothing runs at rest.
@MainActor
final class ScratchpadService: ObservableObject {
    static let shared = ScratchpadService()

    @Published private(set) var pads: [ScratchpadPad] = []
    @Published private(set) var selectedPadID: UUID?
    /// Shown in place until a write succeeds again.
    @Published private(set) var saveFailed = false
    @Published var text = "" {
        didSet {
            guard hasLoaded, !isReplacingText, var document else { return }
            document.updateSelectedText(text, modifiedAt: Date())
            self.document = document
            pads = document.pads
            scheduleSave()
        }
    }

    private var pendingSave: DispatchWorkItem?
    private var document: ScratchpadDocument?
    private var store = ScratchpadStore()
    private var hasLoaded = false
    private var isReplacingText = false

    private init() {}

    var canAddPad: Bool { pads.count < ScratchpadDocument.maximumPadCount }

    /// Loads the document (applying the retention rule) the first time the pad
    /// shows, and keeps the in-memory copy after that.
    func load() -> Bool {
        if hasLoaded, document != nil {
            flushSave()
            return true
        }
        do {
            apply(try store.load(retention: Defaults[.scratchpadRetention], now: Date()))
            hasLoaded = true
            return true
        } catch {
            hasLoaded = false
            return false
        }
    }

    func commitEdits() {
        flushSave()
    }

    func addPad() {
        guard let next = document?.addingPad() else { return }
        replaceDocument(next)
    }

    func select(_ id: UUID) {
        guard id != selectedPadID, let next = document?.selecting(id) else { return }
        replaceDocument(next)
    }

    func rename(_ id: UUID, to name: String) {
        guard let next = document?.renaming(id, to: name) else { return }
        replaceDocument(next)
    }

    /// The last pad can't go; clearing it is the same as deleting its text.
    func remove(_ id: UUID) {
        if let next = document?.removing(id) {
            replaceDocument(next)
        } else if id == selectedPadID {
            text = ""
        }
    }

    private func replaceDocument(_ next: ScratchpadDocument) {
        apply(next)
        flushSave()
    }

    private func apply(_ next: ScratchpadDocument) {
        document = next
        pads = next.pads
        selectedPadID = next.selectedID
        isReplacingText = true
        text = next.pads.first { $0.id == next.selectedID }?.text ?? ""
        isReplacingText = false
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let document else { return }
        saveFailed = !store.save(document)
    }
}
