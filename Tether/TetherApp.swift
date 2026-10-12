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

    // DiTether is open, so the ringing has already stopped: no banner needed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
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
