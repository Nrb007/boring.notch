//
//  TodoStore.swift
//  boringNotch
//

import AppKit
import Defaults
@preconcurrency import EventKit

struct TodoList: Identifiable, Equatable {
    let id: String
    let title: String
    let color: NSColor
}

struct TodoItem: Identifiable, Equatable {
    let id: String
    var title: String
    var done: Bool
    var due: Date?
    var hasDueTime: Bool
    var listID: String
    var listColor: NSColor
}

/// The to-do list beside the calendar on the home page, backed by Reminders (including iCloud lists).
/// Shows incomplete reminders from every list; checking one off completes it in Reminders.
@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var accessDenied = false
    /// Every reminder list, for choosing which ones the to-do list shows.
    @Published private(set) var lists: [TodoList] = []

    private let store = EKEventStore()
    /// Reminders checked off while the list is showing stay visible (struck through) until the next
    /// refresh, so they don't vanish out from under the pointer.
    private var justCompleted: [String: TodoItem] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        updateAccessState()
        Task { [weak self] in
            for await _ in Defaults.updates(.todoHiddenListIDs, initial: false) {
                await self?.reload()
            }
        }
    }

    // MARK: Lists

    func isShown(_ list: TodoList) -> Bool { !Defaults[.todoHiddenListIDs].contains(list.id) }

    func setShown(_ list: TodoList, _ shown: Bool) {
        if shown { Defaults[.todoHiddenListIDs].remove(list.id) } else { Defaults[.todoHiddenListIDs].insert(list.id) }
    }

    /// Loads the lists without fetching reminders, for Settings.
    func loadLists() {
        updateAccessState()
        guard hasAccess else { lists = []; return }
        lists = store.calendars(for: .reminder)
            .map { TodoList(id: $0.calendarIdentifier, title: $0.title, color: $0.color ?? .systemGray) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Access

    private func updateAccessState() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        hasAccess = status == .fullAccess
        accessDenied = status == .denied || status == .restricted
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToReminders()
        updateAccessState()
        if accessDenied,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
        await reload()
    }

    // MARK: Loading

    /// Called when the list appears: drops reminders checked off last time and fetches fresh ones.
    func refresh() async {
        justCompleted.removeAll()
        updateAccessState()
        await reload()
    }

    private func reload() async {
        loadLists()
        guard hasAccess else {
            items = []
            return
        }
        let hidden = Defaults[.todoHiddenListIDs]
        let calendars = store.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else {
            items = []
            return
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        var loaded = reminders.map(Self.item(from:))
        let loadedIDs = Set(loaded.map(\.id))
        loaded += justCompleted.values.filter { !loadedIDs.contains($0.id) && !hidden.contains($0.listID) }
        items = loaded.sorted(by: Self.order)
    }

    private static func item(from reminder: EKReminder) -> TodoItem {
        let components = reminder.dueDateComponents
        return TodoItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            done: reminder.isCompleted,
            due: components.flatMap { Calendar.current.date(from: $0) },
            hasDueTime: components?.hour != nil,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            listColor: reminder.calendar?.color ?? .systemGray
        )
    }

    /// Dated reminders first, soonest first; undated ones after, in title order.
    private static func order(_ a: TodoItem, _ b: TodoItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    // MARK: Editing

    func toggle(_ item: TodoItem) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = !item.done
        do {
            try store.save(reminder, commit: true)
        } catch {
            NSLog("Failed to update reminder: \(error)")
            return
        }
        var updated = item
        updated.done.toggle()
        if updated.done { justCompleted[item.id] = updated } else { justCompleted[item.id] = nil }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
    }

    func openReminders() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
