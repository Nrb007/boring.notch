// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ClipboardHistorySupport.swift,
// adapted for boring.notch: the entry model, retention and size bounds, search and its cache, the
// privacy checks (concealed/transient marks, sensitive-looking text) and the pasteboard helpers.
// The history window's layout, keyboard navigation, batch selection, JSON pretty printing and OCR
// sizing aren't ported; the history lives in the notch's Utilities tab.

import AppKit
import Defaults
import SwiftUI

// MARK: - Settings

extension Defaults.Keys {
    /// Recent entries kept (pinned ones don't count).
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: 50)
    /// Unpinned entries older than this many days go; 0 keeps them.
    static let clipboardHistoryRetentionDays = Key<Int>("clipboardHistoryRetentionDays", default: 0)
    static let clipboardHistoryIncludeImagesFiles = Key<Bool>("clipboardHistoryIncludeImagesFiles", default: true)
    static let clipboardHistoryFilterSensitiveText = Key<Bool>("clipboardHistoryFilterSensitiveText", default: false)
    /// Bundle identifiers whose copies are never saved.
    static let clipboardHistoryIgnoredApps = Key<[String]>("clipboardHistoryIgnoredApps", default: [])
    static let clipboardAutoClearOnDelay = Key<Bool>("clipboardAutoClearOnDelay", default: false)
    static let clipboardAutoClearDelay = Key<Int>("clipboardAutoClearDelay", default: ClipboardHistoryLimits.defaultAutoClearDelay)
    static let clipboardAutoClearOnSleep = Key<Bool>("clipboardAutoClearOnSleep", default: false)
    static let clipboardAutoClearOnDisplaySleep = Key<Bool>("clipboardAutoClearOnDisplaySleep", default: false)
    static let clipboardAutoClearOnScreenLock = Key<Bool>("clipboardAutoClearOnScreenLock", default: false)
}

enum ClipboardHistoryLimits {
    static let allowedLimits = [20, 50, 100, 250, 500, 1_000]
    static let allowedRetentionDays = [1, 7, 30, 90, 365, 0]
    static let autoClearDelayRange = 5...3_600
    static let defaultAutoClearDelay = 20

    static func sanitizedLimit(_ value: Int) -> Int {
        allowedLimits.contains(value) ? value : 50
    }

    static func sanitizedRetentionDays(_ value: Int) -> Int {
        allowedRetentionDays.contains(value) ? value : 0
    }

    static func sanitizedAutoClearDelay(_ seconds: Int) -> Int {
        min(max(seconds, autoClearDelayRange.lowerBound), autoClearDelayRange.upperBound)
    }

    static func retentionLabel(days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    static func sanitizedBundleIdentifierList(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bundleIDs {
            let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, seen.insert(bundleID).inserted else { continue }
            result.append(bundleID)
        }
        return result
    }
}

// MARK: - Polling

/// Main-thread capture admission. Expiring a result does not release the
/// actual queued read; stop/start must not release it either.
struct ClipboardHistoryCaptureState {
    private(set) var generation = 0
    private(set) var inFlight = false
    private(set) var needsBaseline = true

    mutating func restart() {
        generation &+= 1
        needsBaseline = true
    }

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func begin() -> Int? {
        guard !inFlight else { return nil }
        inFlight = true
        generation &+= 1
        return generation
    }

    func accepts(_ token: Int) -> Bool {
        token == generation
    }

    mutating func expire(_ token: Int) {
        if accepts(token) { invalidate() }
    }

    mutating func finish() {
        inFlight = false
    }

    mutating func didBaseline() {
        needsBaseline = false
    }
}

/// Dictation apps such as Superwhisper type by putting their text on the
/// clipboard, pasting it, and putting back whatever was there a moment later.
/// An explicit temporary-content mark lets history recognize that return
/// without treating ordinary repeated copies as a paste-and-restore.
enum ClipboardHistoryPasteRestore {
    static let window: TimeInterval = 3

    static func isWithinWindow(capturedAt: Date, now: Date) -> Bool {
        now >= capturedAt && now.timeIntervalSince(capturedAt) <= window
    }
}

/// Decides whether a polled pasteboard change count is a new copy.
///
/// The count normally only grows, but it lives in the pasteboard server: when
/// that process restarts, the new one's count begins again near zero. A plain
/// `read > last` check would then reject every later copy for days.
enum ClipboardHistoryChangeCount {
    /// The count to adopt, or nil when the read carries nothing new.
    /// - Parameters:
    ///   - read: the count observed by this poll.
    ///   - since: the last known count when this poll was scheduled; only a
    ///     server restart can make `read` lower than it.
    ///   - last: the last known count now, which one of our own writes may
    ///     have raised past `read` while it was in flight.
    static func accepted(read: Int, since: Int, last: Int) -> Int? {
        if read < since { return read }
        return read > last ? read : nil
    }
}

// MARK: - Entries

enum ClipboardHistoryEntryKind: String, Codable {
    case text
    case image
    case files
}

struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    /// The content for text entries; empty for images and files, whose display
    /// strings are derived so they never go stale in storage.
    var text: String
    var copiedAt: Date
    var pinnedAt: Date?
    let kind: ClipboardHistoryEntryKind
    /// Absolute paths for `.files` entries, in the order they were copied.
    let filePaths: [String]
    /// PNG file name inside the clipboard image store for `.image` entries.
    let imageFile: String?
    /// SHA-256 of the PNG data, so re-copying the same image refreshes the
    /// existing entry instead of storing a duplicate file.
    let imageHash: String?
    let imageWidth: Int?
    let imageHeight: Int?
    /// The app the copy came from, when the history could tell.
    var sourceBundleID: String?

    init(id: UUID = UUID(),
         text: String,
         copiedAt: Date = Date(),
         pinnedAt: Date? = nil,
         kind: ClipboardHistoryEntryKind = .text,
         filePaths: [String] = [],
         imageFile: String? = nil,
         imageHash: String? = nil,
         imageWidth: Int? = nil,
         imageHeight: Int? = nil) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.pinnedAt = pinnedAt
        self.kind = kind
        self.filePaths = filePaths
        self.imageFile = imageFile
        self.imageHash = imageHash
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    var isPinned: Bool { pinnedAt != nil }

    var fileNames: [String] {
        filePaths.map { ($0 as NSString).lastPathComponent }
    }

    var imageDimensionsLabel: String {
        guard let imageWidth, let imageHeight else { return "" }
        return "\(imageWidth)×\(imageHeight)"
    }

    /// Width over height of a copied image, for sizing its placeholder.
    var imageAspectRatio: CGFloat? {
        guard let imageWidth, let imageHeight, imageWidth > 0, imageHeight > 0 else { return nil }
        return CGFloat(imageWidth) / CGFloat(imageHeight)
    }

    /// One line of the entry, bounded so a huge text is never copied again
    /// just to draw its row.
    var preview: String {
        switch kind {
        case .text:
            let prefix = text.prefix(ClipboardHistoryEditing.previewCharacters)
            let collapsed = prefix
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = collapsed.isEmpty ? String(prefix) : collapsed
            return prefix.endIndex == text.endIndex ? visible : visible + "…"
        case .image:
            return imageDimensionsLabel
        case .files:
            return fileNames.joined(separator: ", ")
        }
    }

    /// A short excerpt for a hover tooltip.
    var tooltip: String {
        switch kind {
        case .text:
            let prefix = text.prefix(ClipboardHistoryEditing.tooltipCharacters)
            return prefix.endIndex == text.endIndex ? String(prefix) : String(prefix) + "…"
        case .image:
            return "\(ClipboardHistoryEntry.imageLabel) · \(imageDimensionsLabel)"
        case .files:
            return filePaths.joined(separator: "\n")
        }
    }

    static let imageLabel = "Image"

    /// Same clipboard content, regardless of when it was copied: re-copying
    /// refreshes the existing entry instead of duplicating it.
    func matchesContent(of other: ClipboardHistoryEntry) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .text: return text == other.text
        case .image: return imageHash != nil && imageHash == other.imageHash
        case .files: return filePaths == other.filePaths
        }
    }

    /// What the search box can match. Image entries carry the label plus
    /// dimensions so typing "image" finds them.
    var searchableText: String {
        switch kind {
        case .text: return text
        case .image: return "\(Self.imageLabel) png \(imageDimensionsLabel)"
        case .files:
            let names = fileNames.joined(separator: " ")
            let hasImage = filePaths.contains { ClipboardHistoryImageSupport.isImageFileName($0) }
            return hasImage ? "\(Self.imageLabel) \(names)" : names
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, copiedAt, pinnedAt, kind, filePaths, imageFile, imageHash, imageWidth, imageHeight
        case sourceBundleID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        copiedAt = try container.decodeIfPresent(Date.self, forKey: .copiedAt) ?? Date()
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        kind = try container.decodeIfPresent(ClipboardHistoryEntryKind.self, forKey: .kind) ?? .text
        filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        imageFile = try container.decodeIfPresent(String.self, forKey: .imageFile)
        imageHash = try container.decodeIfPresent(String.self, forKey: .imageHash)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
    }
}

enum ClipboardHistoryEditing {
    /// A copied document should stay available, while a pathological
    /// pasteboard payload still has a firm in-memory and on-disk bound.
    static let maxCharacters = 1_000_000
    /// Tighter than Vorssaint's (64 MB / 96 MB): the notch keeps the whole
    /// history in memory for as long as the app runs.
    static let maxStoredTextUTF8Bytes = 16 * 1_024 * 1_024
    static let maxEncodedHistoryBytes = 24 * 1_024 * 1_024
    /// Rows only need enough text to fill their visible line.
    static let previewCharacters = 2_000
    static let tooltipCharacters = 200

    struct EncodedHistory {
        let entries: [ClipboardHistoryEntry]
        let data: Data
    }

    /// An unpinned entry lands at the top of the recent list, so it counts as
    /// just used: keeping its original copy date would let the retention
    /// window drop it on the spot and silently undo the unpin.
    static func unpinned(_ entry: ClipboardHistoryEntry, now: Date = Date()) -> ClipboardHistoryEntry {
        var entry = entry
        entry.pinnedAt = nil
        entry.copiedAt = now
        return entry
    }

    /// `retentionDays` drops recent entries copied longer ago than that, even
    /// under `recentLimit`; 0 keeps them. Pinned entries never expire.
    static func retainedEntries(_ entries: [ClipboardHistoryEntry],
                                recentLimit: Int,
                                retentionDays: Int = 0,
                                now: Date = Date(),
                                textByteLimit: Int = maxStoredTextUTF8Bytes) -> [ClipboardHistoryEntry] {
        var remainingBytes = max(0, textByteLimit)
        func retained(_ candidates: [ClipboardHistoryEntry], limit: Int?) -> [ClipboardHistoryEntry] {
            var result: [ClipboardHistoryEntry] = []
            for entry in candidates {
                if let limit, result.count >= limit { break }
                let byteCount = entry.kind == .text ? entry.text.utf8.count : 0
                guard byteCount <= remainingBytes else { continue }
                remainingBytes -= byteCount
                result.append(entry)
            }
            return result
        }
        let pinned = retained(entries.filter(\.isPinned), limit: nil)
        let recentLimitOrNil = recentLimit <= 0 ? nil : recentLimit
        let cutoff = retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 86_400) : nil
        let recent = retained(entries.filter { entry in
            guard !entry.isPinned else { return false }
            guard let cutoff else { return true }
            return entry.copiedAt >= cutoff
        }, limit: recentLimitOrNil)
        return pinned + recent
    }

    static func preservesPinnedEntries(from original: [ClipboardHistoryEntry],
                                       in retained: [ClipboardHistoryEntry]) -> Bool {
        let retainedIDs = Set(retained.map(\.id))
        return original.lazy.filter(\.isPinned).allSatisfy { retainedIDs.contains($0.id) }
    }

    static func canLoadEncodedHistory(byteCount: Int?) -> Bool {
        guard let byteCount else { return false }
        return byteCount >= 0 && byteCount <= maxEncodedHistoryBytes
    }

    /// Whether the pinned entries alone still fit the saved file. The encoder
    /// keeps pinned entries first and drops whatever no longer fits, so a pin
    /// that fails this check would lose a pinned entry.
    static func pinnedEntriesFit(_ entries: [ClipboardHistoryEntry],
                                 byteLimit: Int = maxEncodedHistoryBytes) -> Bool {
        let pinned = entries.filter(\.isPinned)
        // JSON escaping turns one UTF-8 byte into at most six, and an entry's
        // other fields stay well under 512 bytes, so a small pinned set is
        // never encoded just to be measured.
        let rawBound = pinned.reduce(0) { total, entry in
            total + 512 + entry.text.utf8.count + (entry.imageFile?.utf8.count ?? 0)
                + entry.filePaths.reduce(0) { $0 + $1.utf8.count + 3 }
        }
        guard rawBound > (byteLimit - 2) / 6 else { return true }
        let encoder = JSONEncoder()
        var encodedSize = 2
        for (offset, entry) in pinned.enumerated() {
            guard let encoded = try? encoder.encode(entry) else { return false }
            encodedSize += encoded.count + (offset == 0 ? 0 : 1)
            if encodedSize > byteLimit { return false }
        }
        return true
    }

    /// Encodes a readable snapshot without ever writing a file the next launch
    /// would reject: the bound is enforced on the actual encoded bytes.
    static func encodedHistory(_ entries: [ClipboardHistoryEntry],
                               byteLimit: Int = maxEncodedHistoryBytes) -> EncodedHistory? {
        guard byteLimit >= 2 else { return nil }
        let encoder = JSONEncoder()
        let ordered = entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
        var retained: [ClipboardHistoryEntry] = []
        var encodedEntries: [Data] = []
        var encodedSize = 2

        for entry in ordered {
            guard let encoded = try? encoder.encode(entry) else { return nil }
            let addedSize = encoded.count + (encodedEntries.isEmpty ? 0 : 1)
            guard encodedSize + addedSize <= byteLimit else { continue }
            retained.append(entry)
            encodedEntries.append(encoded)
            encodedSize += addedSize
        }

        var data = Data(capacity: encodedSize)
        data.append(0x5B)
        for (index, encoded) in encodedEntries.enumerated() {
            if index > 0 { data.append(0x2C) }
            data.append(encoded)
        }
        data.append(0x5D)
        return EncodedHistory(entries: retained, data: data)
    }
}

// MARK: - Search

struct ClipboardHistorySearchFolded: Equatable {
    let searchableText: String
    let normalizedText: String
    let words: Set<String>

    init(searchableText: String) {
        self.searchableText = searchableText
        let folded = ClipboardHistorySearch.normalized(searchableText)
        self.normalizedText = folded
        self.words = ClipboardHistorySearch.words(in: folded)
    }
}

struct ClipboardHistorySearchCandidate: Equatable {
    var index: Int
    var isPinned: Bool
    var normalizedText: String
    var words: Set<String>
}

/// Folds each entry's text once and keeps it until the entry changes, so a
/// keystroke in the search field doesn't fold every long text again.
struct ClipboardHistorySearchCache {
    private var foldedEntries: [UUID: ClipboardHistorySearchFolded] = [:]
    private var cachedCandidates: [ClipboardHistorySearchCandidate] = []
    private var cachedStamp: Int?

    mutating func candidates(for entries: [ClipboardHistoryEntry], stamp: Int) -> [ClipboardHistorySearchCandidate] {
        if cachedStamp == stamp { return cachedCandidates }
        var nextFolded: [UUID: ClipboardHistorySearchFolded] = [:]
        nextFolded.reserveCapacity(entries.count)
        let candidates = entries.enumerated().map { index, entry in
            let searchable = entry.searchableText
            let folded: ClipboardHistorySearchFolded
            if let existing = foldedEntries[entry.id], existing.searchableText == searchable {
                folded = existing
            } else {
                folded = ClipboardHistorySearchFolded(searchableText: searchable)
            }
            nextFolded[entry.id] = folded
            return ClipboardHistorySearchCandidate(index: index, isPinned: entry.isPinned,
                                                   normalizedText: folded.normalizedText, words: folded.words)
        }
        foldedEntries = nextFolded
        cachedStamp = stamp
        cachedCandidates = candidates
        return candidates
    }

    /// Drops what belongs to entries that are gone, so a cleared history's
    /// text doesn't linger in memory.
    mutating func prune(keeping entries: [ClipboardHistoryEntry]) {
        guard !entries.isEmpty else { clear(); return }
        guard !foldedEntries.isEmpty || !cachedCandidates.isEmpty else { return }
        cachedCandidates.removeAll()
        cachedStamp = nil
        let ids = Set(entries.map(\.id))
        foldedEntries = foldedEntries.filter { ids.contains($0.key) }
    }

    mutating func clear() {
        foldedEntries.removeAll()
        cachedCandidates.removeAll()
        cachedStamp = nil
    }
}

enum ClipboardHistorySearch {
    static func rankedIndexes(candidates: [ClipboardHistorySearchCandidate], matching query: String) -> [Int] {
        let normalizedQuery = normalized(query)
        let tokens = searchTokens(for: normalizedQuery)
        guard !tokens.isEmpty else { return candidates.map(\.index) }

        return candidates
            .compactMap { candidate -> (index: Int, score: Int)? in
                let text = candidate.normalizedText
                guard tokens.allSatisfy({ text.contains($0) }) else { return nil }
                return (candidate.index, score(for: text, words: candidate.words, normalizedQuery: normalizedQuery,
                                               tokens: tokens, isPinned: candidate.isPinned))
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            .map(\.index)
    }

    /// Non-empty search tokens from a raw query, split by whitespace.
    static func searchTokens(for query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    /// Every matching range of `tokens` in `text`, ignoring case, diacritics and width.
    static func highlightRanges(in text: String, tokens: [String]) -> [Range<String.Index>] {
        guard !text.isEmpty, !tokens.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            var search = text.startIndex..<text.endIndex
            while search.lowerBound < text.endIndex,
                  let r = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: search) {
                ranges.append(r)
                if r.upperBound == search.lowerBound { break }
                search = r.upperBound..<text.endIndex
            }
        }
        return ranges
    }

    static func words(in normalizedText: String) -> Set<String> {
        Set(normalizedText.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func score(for text: String, words: Set<String>, normalizedQuery: String,
                              tokens: [String], isPinned: Bool) -> Int {
        var score = isPinned ? 30 : 0
        if text == normalizedQuery { score += 1_200 }
        if text.hasPrefix(normalizedQuery) { score += 900 }
        if text.contains(normalizedQuery) { score += 700 }
        for token in tokens {
            if words.contains(token) {
                score += 140
            } else if words.contains(where: { $0.hasPrefix(token) }) {
                score += 80
            } else {
                score += 40
            }
        }
        return score
    }

    static func normalized(_ value: String) -> String {
        value
            // No locale: Turkish folds a dotted I to a dotless one.
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Marks what a search matched in a row's text, by weight alone (the notch
/// draws its text in white).
enum ClipboardSearchHighlight {
    static let visibleCharacters = 500

    static func text(_ string: String, tokens: [String], fontSize: CGFloat) -> Text {
        guard !tokens.isEmpty else { return Text(string) }
        var visible = string
        if let end = string.index(string.startIndex, offsetBy: visibleCharacters, limitedBy: string.endIndex),
           end < string.endIndex {
            visible = String(string[..<end]) + "…"
        }
        var attributed = AttributedString(visible)
        for range in ClipboardHistorySearch.highlightRanges(in: visible, tokens: tokens) {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].font = .system(size: fontSize, weight: .bold)
            attributed[attributedRange].foregroundColor = .teal
        }
        return Text(attributed)
    }
}

// MARK: - Pasteboard text and privacy

enum ClipboardHistoryPasteboardText {
    /// Prefers a copied link's URL over the page title some browsers put in
    /// the plain-text slot, but only when the two are the same link.
    static func preferredText(webURLString: String?, plainText: String?) -> String? {
        let plain = trimmed(plainText)
        if let plain, let normalizedPlain = normalizedWebURL(plain) {
            return normalizedPlain
        }
        guard let webURL = normalizedWebURL(webURLString) else { return plain }
        guard let plain else { return webURL }
        return shouldPreferWebURL(webURL, over: plain) ? webURL : plain
    }

    private static func shouldPreferWebURL(_ webURL: String, over plain: String) -> Bool {
        guard !plain.contains(where: \.isWhitespace) else { return false }
        if plain.hasPrefix("//") { return true }
        let stripped = stripWebScheme(webURL)
        return plain == stripped.withSlashes || plain == stripped.withoutSlashes
    }

    private static func normalizedWebURL(_ raw: String?) -> String? {
        guard let text = trimmed(raw),
              !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url.absoluteString
    }

    private static func stripWebScheme(_ value: String) -> (withSlashes: String, withoutSlashes: String) {
        let lower = value.lowercased()
        let withSlashes: String
        if lower.hasPrefix("http://") {
            withSlashes = "//" + String(value.dropFirst("http://".count))
        } else if lower.hasPrefix("https://") {
            withSlashes = "//" + String(value.dropFirst("https://".count))
        } else {
            withSlashes = value
        }
        return (withSlashes, String(withSlashes.drop { $0 == "/" }))
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension NSPasteboard.PasteboardType {
    /// The nspasteboard.org mark naming the app that wrote the pasteboard.
    static let clipboardHistorySource = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// Added by the system to a copy that arrived over Universal Clipboard.
    static let clipboardHistoryRemote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
}

enum ClipboardHistorySensitiveText {
    /// The mark an app puts on the pasteboard to say the content is a secret
    /// and must not be recorded anywhere (password managers write it).
    static let concealedPasteboardType = "org.nspasteboard.ConcealedType"

    static func isConcealed(_ types: [String]) -> Bool {
        types.contains(concealedPasteboardType)
    }

    /// Content an app is about to take back, or made up rather than copied
    /// (a dictation app pasting what it heard). Neither is worth keeping.
    static let transientPasteboardTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]

    static func isTransient(_ types: [String]) -> Bool {
        types.contains(where: transientPasteboardTypes.contains)
    }

    // A mention of "token" in a command or source code is not a credential.
    // Require a named field with a nonempty value, including environment
    // variables, quoted JSON keys, Authorization headers and --password VALUE.
    private static let credentialName = #"(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|authorization)"#
    private static let credentialEnding = #"(?:[_-]?(?:access[_-]?)?key(?:[_-]?base)?|[_-]?confirmation|[_-]?\d{1,3})?"#
    private static let credentialAssignment = try? NSRegularExpression(
        pattern: #"(?<![\w-])(?:[\w-]*\#(credentialName)\#(credentialEnding)["']?[ \t]*[:=][ \t]*|--[\w-]*\#(credentialName)\#(credentialEnding)[ \t]+)["']?[^\s"'`,;{}\[\]]"#,
        options: [.caseInsensitive]
    )

    static func looksSensitive(_ text: String) -> Bool {
        if credentialAssignment?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        if isWebURL(text) { return false }
        // A UUID is nobody's secret, though it fits the shape below exactly.
        if isIdentifierCode(text) { return false }
        guard text.count >= 20, text.count <= 160, !text.contains(where: { $0.isWhitespace }) else {
            return false
        }
        let hasLetter = text.contains { $0.isLetter }
        let hasDigit = text.contains { $0.isNumber }
        let hasSymbol = text.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
        return hasLetter && hasDigit && hasSymbol
    }

    private static func isIdentifierCode(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{"), value.hasSuffix("}") {
            value = String(value.dropFirst().dropLast())
        }
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }
}

enum ClipboardHistoryImageSupport {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp", "ico", "icns", "svg", "avif",
    ]

    static func isImageFileName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isImageFilePath(_ path: String) -> Bool {
        isImageFileName(path) && FileManager.default.fileExists(atPath: path)
    }
}

// MARK: - Private files

/// Owner-only storage under the app's Application Support folder (inside the
/// sandbox container). Directories are 0700, files 0600 and written with
/// complete file protection, and both are set again on every write.
enum ClipboardFileStore {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    @discardableResult
    static func createDirectory(at url: URL) -> Bool {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return false }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return true
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
