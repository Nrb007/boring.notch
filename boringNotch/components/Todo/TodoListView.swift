//
//  TodoListView.swift
//  boringNotch
//

import SwiftUI

/// Sits in the calendar's spot on the home page; swipe left on the calendar to get here.
/// Shows your incomplete Reminders.
struct TodoListView: View {
    @ObservedObject private var store = TodoStore.shared

    private var remaining: Int { store.items.filter { !$0.done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button { store.openReminders() } label: {
                    Text("To Do")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Open Reminders · right-click to choose lists")
                .contextMenu { listMenu }
                Spacer()
                if store.hasAccess && !store.items.isEmpty {
                    Text(remaining == 0 ? "All done" : "\(remaining) left")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                }
            }

            if !store.hasAccess {
                placeholder(icon: "checklist", title: "Show your reminders") {
                    Button(store.accessDenied ? "Open Settings" : "Allow Access") {
                        Task { await store.requestAccess() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if store.items.isEmpty {
                placeholder(icon: "checkmark.circle", title: "Nothing to do") { EmptyView() }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.items) { item in
                            TodoRow(item: item)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task { await store.refresh() }
    }

    @ViewBuilder private var listMenu: some View {
        if store.lists.isEmpty {
            Text("No reminder lists")
        } else {
            Section("Show Lists") {
                ForEach(store.lists) { list in
                    Toggle(list.title, isOn: Binding(
                        get: { store.isShown(list) },
                        set: { store.setShown(list, $0) }
                    ))
                }
            }
        }
        Divider()
        Button("Open Reminders") { store.openReminders() }
    }

    private func placeholder<Action: View>(icon: String, title: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(title)
                .font(.subheadline)
                .foregroundColor(.white)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TodoRow: View {
    let item: TodoItem
    @ObservedObject private var store = TodoStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { store.toggle(item) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: item.listColor).opacity(item.done ? 1 : 0.9))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .foregroundColor(item.done ? Color(white: 0.5) : .white)
                    .strikethrough(item.done, color: Color(white: 0.5))
                    .lineLimit(2)
                if let due = item.due {
                    Text(dueLabel(due))
                        .font(.caption2)
                        .foregroundColor(due < .now && !item.done ? .red.opacity(0.85) : Color(white: 0.55))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = item.hasDueTime ? " " + date.formatted(date: .omitted, time: .shortened) : ""
        if calendar.isDateInToday(date) { return "Today" + time }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" + time }
        if calendar.isDateInYesterday(date) { return "Yesterday" + time }
        return date.formatted(.dateTime.month(.abbreviated).day()) + time
    }
}
