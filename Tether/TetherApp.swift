import SwiftUI
import UIKit
import UserNotifications

/// Owning the model here (instead of in a view) means the phone is ready to receive events from the
/// watch even when iOS launches the app silently in the background.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = PhoneModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Being terminated (for example swiped away while running in the background): stop everything.
    func applicationWillTerminate(_ application: UIApplication) {
        model.stopBackgroundWork()
    }

    // DiTether is open, so the ringing has already stopped: no banner needed. A DiTAG left behind
    // still shows, since you may be looking at another tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // DiTAG notifications (left behind, getting far, battery) still show while DiTether is open.
        if notification.request.identifier.hasPrefix("ditag.") {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    /// "Left it on purpose" on the DiTAG alert (on the iPhone or the watch): quiet until it is back.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let tagID = (response.notification.request.content.userInfo[DiTagManager.tagIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if action == DiTagManager.leaveItAction, let tagID {
                self.model.diTag.snoozeUntilBack(tagID)
            }
            completionHandler()
        }
    }
}

@main
struct TetherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.model)
        }
    }
}
