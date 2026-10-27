// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), GeneralPasteboardAccess.swift
// and ClipboardHistoryWrite.swift, adapted for boring.notch (renamed to stay inside the Clipboard
// utility; the injectable clock and deadline scheduler used by Vorssaint's tests are dropped).

import AppKit

/// Serializes every access the clipboard utility makes to the general
/// pasteboard. NSPasteboard keeps a mutable type cache on its shared instance,
/// so reading it from two queues at once can race inside AppKit, and a read has
/// no time limit: content can be promised and rendered only on demand, so an
/// app that stops answering leaves the reader hanging. Hence one serial lane,
/// off the main thread, and no way to wait for it.
final class ClipboardPasteboardAccess: @unchecked Sendable {
    static let shared = ClipboardPasteboardAccess()

    private let queue = DispatchQueue(label: "boringNotch.clipboard.pasteboard", qos: .utility)

    private static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Runs `work` on the lane and hands its result to `completion` on the main queue.
    func async<T>(_ work: @escaping () -> T, then completion: @escaping (T) -> Void) {
        let box = UncheckedBox((work, completion))
        queue.async {
            let result = UncheckedBox(box.value.0())
            DispatchQueue.main.async { box.value.1(result.value) }
        }
    }

    /// A deadline limits result delivery and prevents expired queued work from
    /// starting. It cannot interrupt an AppKit call already in progress.
    /// `didFinish` runs on main only when the actual queue operation ends, even
    /// if `completion` already received nil at the deadline, so callers can
    /// keep admission bounded while a provider is unresponsive.
    func async<T>(timeout: TimeInterval,
                  _ work: @escaping (_ isExpired: () -> Bool) -> T?,
                  then completion: @escaping (T?) -> Void,
                  didFinish: @escaping (T?) -> Void = { _ in }) {
        let deadline = Self.now() + timeout
        let delivery = ClipboardResultDelivery(completion)
        let deadlineItem = DispatchWorkItem { delivery.complete(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadlineItem)
        let box = UncheckedBox((work, didFinish))
        queue.async {
            let isExpired = { Self.now() >= deadline }
            let value = UncheckedBox(isExpired() ? nil : box.value.0(isExpired))
            DispatchQueue.main.async {
                deadlineItem.cancel()
                box.value.1(value.value)
                delivery.complete(isExpired() ? nil : value.value)
            }
        }
    }
}

/// Carries values the lane hands between the main thread and its own queue.
/// Every value crosses in one direction at a time, never concurrently.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Both deadline and queue completion deliver on main. Clearing the callback
/// before invoking it also makes reentrant callers safe.
private final class ClipboardResultDelivery<Value>: @unchecked Sendable {
    private var completion: ((Value?) -> Void)?

    init(_ completion: @escaping (Value?) -> Void) {
        self.completion = completion
    }

    func complete(_ value: Value?) {
        precondition(Thread.isMainThread)
        let callback = completion
        completion = nil
        callback?(value)
    }
}

struct ClipboardHistoryWriteResult {
    let succeeded: Bool
    let changeCount: Int
}

/// What a history entry puts back on the pasteboard.
enum ClipboardHistoryWrite {
    case text(String)
    case image(png: Data, tiff: Data?)
    case files([NSURL])

    /// Expiry stops subsequent writes. Once cleared, always read the final
    /// change count so history can exclude our own mutation, even after a
    /// timeout. A call in progress cannot be cancelled or a partial write undone.
    func write(to pasteboard: NSPasteboard, isExpired: () -> Bool) -> ClipboardHistoryWriteResult? {
        guard !isExpired() else { return nil }
        _ = pasteboard.clearContents()

        var succeeded = false
        if !isExpired() {
            switch self {
            case let .text(text):
                succeeded = pasteboard.setString(text, forType: .string)
            case let .image(png, tiff):
                succeeded = pasteboard.setData(png, forType: .png)
                if succeeded, let tiff, !isExpired() {
                    _ = pasteboard.setData(tiff, forType: .tiff)
                }
            case let .files(urls):
                succeeded = pasteboard.writeObjects(urls)
            }
        }
        return ClipboardHistoryWriteResult(succeeded: !isExpired() && succeeded, changeCount: pasteboard.changeCount)
    }
}
