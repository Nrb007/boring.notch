//
//  NotchUtility.swift
//  boringNotch
//
//  Utilities are small tools that live in the notch's Utilities tab. To add one, put its files in
//  a folder under utilities/ (the folder is synced into the target automatically), add a case to
//  UtilityID and an entry to UtilityRegistry. It then gets a tile, a page with a back button, and
//  an on/off switch in Settings → Utilities.
//

import Defaults
import SwiftUI

enum UtilityID: String, CaseIterable, Codable, Defaults.Serializable {
    case timer
    case scratchpad
}

struct NotchUtility: Identifiable {
    let id: UtilityID
    let title: String
    let symbol: String
    let tint: Color
    /// Pages with text input need the notch window to take keyboard focus while they're shown.
    let needsKeyboard: Bool
    let makePage: () -> AnyView
}

enum UtilityRegistry {
    static let all: [NotchUtility] = [
        NotchUtility(id: .timer, title: "Timer", symbol: "timer", tint: .orange, needsKeyboard: false) {
            AnyView(TimerUtilityView())
        },
        NotchUtility(id: .scratchpad, title: "Scratchpad", symbol: "note.text", tint: .yellow, needsKeyboard: true) {
            AnyView(ScratchpadUtilityView())
        },
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
    static let enabledUtilities = Key<Set<UtilityID>>("enabledUtilities", default: Set(UtilityID.allCases))
}

/// Which utility page is open in the Utilities tab; nil shows the grid of tiles.
@MainActor
final class UtilitiesState: ObservableObject {
    static let shared = UtilitiesState()
    @Published var openUtility: UtilityID?
    private init() {}

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
