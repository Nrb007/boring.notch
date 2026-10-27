// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ScratchpadSupport.swift
// and ScratchpadStore.swift: the tabbed document, its retention rule, list continuation and the
// on-disk store. Vorssaint's Markdown preview, formatting marks and export aren't ported yet.

import Defaults
import Foundation

/// How long each scratchpad keeps text that nobody edits. The check runs only
/// when the pad loads, against the stored edit dates, so it needs no timer.
enum ScratchpadRetention: String, CaseIterable, Defaults.Serializable {
    case never
    case day
    case week
    case month

    /// Seconds the text may sit unedited before it clears; nil keeps forever.
    var maxIdleInterval: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    var title: String {
        switch self {
        case .never: return "Never"
        case .day: return "After a day"
        case .week: return "After a week"
        case .month: return "After a month"
        }
    }
}

extension Defaults.Keys {
    static let scratchpadRetention = Key<ScratchpadRetention>("scratchpadRetention", default: .never)
    static let scratchpadTextSize = Key<Double>("scratchpadTextSize", default: 13)
}

struct ScratchpadPad: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var text: String
    var modifiedAt: Date?
}

/// The whole scratchpad state travels as one small document. Stable ids keep
/// selection independent from names, while array order is the tab order.
struct ScratchpadDocument: Codable, Equatable {
    /// Keeps the tab strip small without limiting the text inside any pad.
    static let maximumPadCount = 8
    static let maximumNameLength = 24
    static let defaultName = "Note"

    var pads: [ScratchpadPad]
    var selectedID: UUID

    static func initial(id: UUID = UUID()) -> ScratchpadDocument {
        let pad = ScratchpadPad(id: id, name: ScratchpadSupport.nextPadName(existingNames: []), text: "", modifiedAt: nil)
        return ScratchpadDocument(pads: [pad], selectedID: pad.id)
    }

    func sanitized() -> ScratchpadDocument {
        var seen = Set<UUID>()
        var cleanPads: [ScratchpadPad] = []
        for pad in pads.prefix(Self.maximumPadCount) where seen.insert(pad.id).inserted {
            let fallback = ScratchpadSupport.nextPadName(existingNames: cleanPads.map(\.name))
            let name = ScratchpadSupport.sanitizedPadName(pad.name)
            cleanPads.append(ScratchpadPad(id: pad.id,
                                           name: name.isEmpty ? fallback : name,
                                           text: pad.text,
                                           modifiedAt: pad.text.isEmpty ? nil : pad.modifiedAt))
        }
        guard !cleanPads.isEmpty else { return .initial() }
        let selection = cleanPads.contains(where: { $0.id == selectedID }) ? selectedID : cleanPads[0].id
        return ScratchpadDocument(pads: cleanPads, selectedID: selection)
    }

    func addingPad(id: UUID = UUID()) -> ScratchpadDocument? {
        guard pads.count < Self.maximumPadCount else { return nil }
        var next = self
        next.pads.append(ScratchpadPad(id: id, name: ScratchpadSupport.nextPadName(existingNames: pads.map(\.name)),
                                       text: "", modifiedAt: nil))
        next.selectedID = id
        return next
    }

    func selecting(_ id: UUID) -> ScratchpadDocument? {
        guard pads.contains(where: { $0.id == id }) else { return nil }
        var next = self
        next.selectedID = id
        return next
    }

    func renaming(_ id: UUID, to proposedName: String) -> ScratchpadDocument? {
        let name = ScratchpadSupport.sanitizedPadName(proposedName)
        guard !name.isEmpty, let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.pads[index].name = name
        return next
    }

    func removing(_ id: UUID) -> ScratchpadDocument? {
        guard pads.count > 1, let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.pads.remove(at: index)
        if selectedID == id {
            next.selectedID = next.pads[min(index, next.pads.count - 1)].id
        }
        return next
    }

    mutating func updateSelectedText(_ text: String, modifiedAt: Date) {
        guard let index = pads.firstIndex(where: { $0.id == selectedID }),
              pads[index].text != text else { return }
        pads[index].text = text
        pads[index].modifiedAt = text.isEmpty ? nil : modifiedAt
    }

    mutating func applyRetention(_ retention: ScratchpadRetention, now: Date) {
        for index in pads.indices where ScratchpadSupport.shouldClear(
            lastEdited: pads[index].modifiedAt, now: now, retention: retention
        ) {
            pads[index].text = ""
            pads[index].modifiedAt = nil
        }
    }
}

enum ScratchpadSupport {
    private static let listMarker = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]?\](?:[ \t]+|$))?"#)

    /// What Return does with the caret at `caret`: in a list item it opens the
    /// next one, with the same marker, a fresh unchecked box for a task and
    /// the next number for a numbered item; on an empty item it ends the list
    /// instead; anywhere else it is a plain line break. `range` is what is
    /// replaced and `caret` the offset after the edit.
    static func lineBreakEdit(in text: String, selection: NSRange) -> (range: NSRange, replacement: String, caret: Int) {
        let plain = (range: selection, replacement: "\n", caret: selection.location + 1)
        let whole = text as NSString
        guard selection.length == 0, selection.location <= whole.length, let listMarker else { return plain }
        let line = whole.lineRange(for: NSRange(location: selection.location, length: 0))
        var content = line
        while content.length > 0, "\n\r".contains(whole.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1))) {
            content.length -= 1
        }
        let lineText = whole.substring(with: content)
        guard let match = listMarker.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))
        else { return plain }
        let markerEnd = content.location + match.range.length
        guard selection.location >= markerEnd else { return plain }
        let lineNS = lineText as NSString
        let prefix = lineNS.substring(with: match.range(at: 1))
        let marker = lineNS.substring(with: match.range(at: 2))
        let spacing = lineNS.substring(with: match.range(at: 3))
        let hasBox = match.range(at: 4).location != NSNotFound
        if selection.location == NSMaxRange(content), match.range.length == lineNS.length || lineNS.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: the list ends, and the marker goes.
            return (content, "", content.location)
        }
        var next = marker
        // The largest number has no next one; its item repeats it.
        if let digits = Int(marker.dropLast()), digits < Int.max, let delimiter = marker.last {
            next = "\(digits + 1)\(delimiter)"
        }
        let replacement = "\n" + prefix + next + spacing + (hasBox ? "[ ] " : "")
        return (selection, replacement, selection.location + (replacement as NSString).length)
    }

    static func sanitizedPadName(_ name: String) -> String {
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(ScratchpadDocument.maximumNameLength))
    }

    static func nextPadName(existingNames: [String]) -> String {
        let base = ScratchpadDocument.defaultName
        let used = Set(existingNames)
        for number in 1...ScratchpadDocument.maximumPadCount where !used.contains("\(base) \(number)") {
            return "\(base) \(number)"
        }
        return "\(base) \(existingNames.count + 1)"
    }

    /// Whether the saved text expired: it only clears when a retention period
    /// is chosen and the last edit is older than that period.
    static func shouldClear(lastEdited: Date?, now: Date, retention: ScratchpadRetention) -> Bool {
        guard let limit = retention.maxIdleInterval, let lastEdited else { return false }
        return now.timeIntervalSince(lastEdited) > limit
    }
}

/// A failed read must never authorize a later autosave over the file it failed to read.
struct ScratchpadStore {
    private(set) var lastSavedDocument: ScratchpadDocument?
    private var canSave = false

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Scratchpad", isDirectory: true)
            .appendingPathComponent("Scratchpad.json")
    }

    mutating func load(retention: ScratchpadRetention, now: Date) throws -> ScratchpadDocument {
        canSave = false
        lastSavedDocument = nil
        guard let url = Self.fileURL else { throw CocoaError(.fileReadUnknown) }
        var loaded: ScratchpadDocument
        do {
            let data = try Data(contentsOf: url)
            loaded = try JSONDecoder().decode(ScratchpadDocument.self, from: data).sanitized()
            lastSavedDocument = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loaded = .initial()
        }
        loaded.applyRetention(retention, now: now)
        canSave = true
        save(loaded)
        return loaded
    }

    @discardableResult
    mutating func save(_ document: ScratchpadDocument) -> Bool {
        guard canSave else { return false }
        if document == lastSavedDocument { return true }
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(document) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            return false
        }
        lastSavedDocument = document
        return true
    }
}
