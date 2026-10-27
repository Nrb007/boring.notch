//
//  NotchUtility.swift
//  boringNotch
//
//  Utilities are small tools that live in the notch's Utilities tab. To add one, put its files in
//  a folder under utilities/ (the folder is synced into the target automatically), add a case to
//  UtilityID and an entry to UtilityRegistry. It then gets a tile, a page with a back button, an
//  on/off switch in Settings → Utilities (plus its own settings section, if it has one), and can
//  show itself in the closed notch through UtilityActivityCenter.
//

import Defaults
import SwiftUI

enum UtilityID: String, CaseIterable, Codable, Defaults.Serializable {
    case timer
    case scratchpad
    case downloads
    case clipboard
    case watch
    case mirror
}

struct NotchUtility: Identifiable {
    let id: UtilityID
    let title: String
    let symbol: String
    let tint: Color
    /// Pages with text input need the notch window to take keyboard focus while they're shown.
    let needsKeyboard: Bool
    let makePage: () -> AnyView
    /// Extra options shown under the utility's switch in Settings → Utilities.
    var makeSettings: (() -> AnyView)?
}

enum UtilityRegistry {
    static let all: [NotchUtility] = [
        NotchUtility(id: .timer, title: "Timer", symbol: "timer", tint: .orange, needsKeyboard: false,
                     makePage: { AnyView(TimerUtilityView()) },
                     makeSettings: { AnyView(TimerSettingsSection()) }),
        NotchUtility(id: .scratchpad, title: "Scratchpad", symbol: "note.text", tint: .yellow, needsKeyboard: true,
                     makePage: { AnyView(ScratchpadUtilityView()) },
                     makeSettings: { AnyView(ScratchpadSettingsSection()) }),
        NotchUtility(id: .downloads, title: "Downloads", symbol: "arrow.down.circle", tint: .blue, needsKeyboard: false,
                     makePage: { AnyView(DownloadsUtilityView()) },
                     makeSettings: { AnyView(DownloadsSettingsSection()) }),
        NotchUtility(id: .clipboard, title: "Clipboard", symbol: "doc.on.clipboard", tint: .teal, needsKeyboard: true,
                     makePage: { AnyView(ClipboardUtilityView()) },
                     makeSettings: { AnyView(ClipboardSettingsSection()) }),
        NotchUtility(id: .watch, title: "Watch", symbol: "eye", tint: .purple, needsKeyboard: false,
                     makePage: { AnyView(WatchUtilityView()) },
                     makeSettings: { AnyView(WatchSettingsSection()) }),
        NotchUtility(id: .mirror, title: "Mirror", symbol: "web.camera", tint: .green, needsKeyboard: false,
                     makePage: { AnyView(MirrorUtilityView()) }),
    ]

    static func utility(_ id: UtilityID) -> NotchUtility? {
        all.first { $0.id == id }
    }

    static var enabled: [NotchUtility] {
        let ids = Defaults[.enabledUtilities]
        return all.filter { ids.contains($0.id) }
    }

    static func isEnabled(_ id: UtilityID) -> Bool {
        Defaults[.enabledUtilities].contains(id)
    }
}

extension Defaults.Keys {
    // Clipboard history records everything you copy, so it's opt-in
    static let enabledUtilities = Key<Set<UtilityID>>("enabledUtilities", default: Set(UtilityID.allCases).subtracting([.clipboard]))
}

/// Which utility page is open in the Utilities tab; nil shows the grid of tiles.
@MainActor
final class UtilitiesState: ObservableObject {
    static let shared = UtilitiesState()
    @Published var openUtility: UtilityID? {
        didSet { if openUtility == nil { releaseHold() } }
    }
    /// True while someone is typing in a utility page: the notch stays open after the mouse
    /// leaves, and closes once the keyboard has been idle for `typingIdleInterval`.
    @Published private(set) var holdsNotchOpen = false
    static let typingIdleInterval: Duration = .milliseconds(2500)
    private var idleTask: Task<Void, Never>?
    private init() {}

    func noteTyping() {
        if !holdsNotchOpen { holdsNotchOpen = true }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingIdleInterval)
            guard !Task.isCancelled else { return }
            self?.holdsNotchOpen = false
        }
    }

    func releaseHold() {
        idleTask?.cancel()
        idleTask = nil
        if holdsNotchOpen { holdsNotchOpen = false }
    }

    func open(_ id: UtilityID) {
        withAnimation(.smooth(duration: 0.25)) {
            openUtility = id
            BoringViewCoordinator.shared.currentView = .utilities
        }
    }

    func close() {
        withAnimation(.smooth(duration: 0.25)) {
            openUtility = nil
        }
    }
}

/// The notch panels refuse keyboard focus so they never steal typing from other apps. A utility
/// page with text input asks for it while it's on screen, and gives it back when it leaves.
enum NotchKeyboardFocus {
    private(set) static var isRequested = false

    @MainActor
    static func request(for view: NSView) {
        isRequested = true
        view.window?.makeKey()
    }

    @MainActor
    static func release(from window: NSWindow?) {
        isRequested = false
        if window?.isKeyWindow == true {
            window?.resignKey()
        }
    }
}

/// What a utility shows in the closed notch: a mark on the left, a short reading on the right.
struct UtilityActivity: Equatable {
    let id: UtilityID
    var symbol: String
    var tint: Color
    var text: String
    /// 0...1 draws a ring around the mark instead of the plain symbol.
    var progress: Double?
    /// Higher wins when several utilities want the closed notch at once.
    var priority: Int = 0
}

/// Utilities publish their closed-notch activity here; the notch shows the highest-priority one
/// (a running timer still comes first). Tapping it opens that utility's page.
@MainActor
final class UtilityActivityCenter: ObservableObject {
    static let shared = UtilityActivityCenter()
    @Published private(set) var activities: [UtilityID: UtilityActivity] = [:]
    private init() {}

    func set(_ activity: UtilityActivity?, for id: UtilityID) {
        if let activity {
            guard activities[id] != activity else { return }
            activities[id] = activity
        } else if activities[id] != nil {
            activities[id] = nil
        }
    }

    /// The activity to show: enabled utilities only, highest priority first.
    var current: UtilityActivity? {
        activities.values
            .filter { UtilityRegistry.isEnabled($0.id) }
            .max { $0.priority < $1.priority }
    }
}
