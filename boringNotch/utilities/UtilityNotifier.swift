//
//  UtilityNotifier.swift
//  boringNotch
//
//  Lets a utility get the user's attention when something it was waiting for happens: a macOS
//  notification banner (clicking it opens the utility's page), and the notch opening to that page
//  for a few seconds.
//

import AppKit
import UserNotifications

extension Notification.Name {
    /// Posted with the UtilityID as the object; the notch opens to that utility's page.
    static let utilityNeedsAttention = Notification.Name("com.boringNotch.utilityNeedsAttention")
}

final class UtilityNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UtilityNotifier()
    private static let utilityKey = "utility"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Shows a banner (asking for permission the first time) and opens the notch to the utility.
    /// `completion` reports whether a banner went out, so callers can play their own sound otherwise.
    func notify(_ utility: UtilityID, title: String, body: String, sound: Bool,
                completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .utilityNeedsAttention, object: utility)
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in completion(false) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
            content.userInfo = [Self.utilityKey: utility.rawValue]
            let request = UNNotificationRequest(identifier: "\(utility.rawValue)-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request) { error in
                Task { @MainActor in completion(error == nil) }
            }
        }
    }

    // Show banners even while the app counts as active, which a notch app often does
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking a banner opens the notch to the utility that sent it
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo[Self.utilityKey] as? String,
           let utility = UtilityID(rawValue: raw) {
            Task { @MainActor in
                NotificationCenter.default.post(name: .utilityNeedsAttention, object: utility)
            }
        }
        completionHandler()
    }
}
