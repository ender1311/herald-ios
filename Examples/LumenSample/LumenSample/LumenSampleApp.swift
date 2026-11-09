import HeraldSDK
import HeraldUI
import SwiftUI
import UserNotifications

@main
struct LumenSampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Herald.configure(appKey: SampleConfig.appKey, endpoint: SampleConfig.endpoint) { options in
            options.logLevel = .debug
        }
        Herald.useDefaultInAppUI(theme: HeraldTheme())
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Herald.shared.setPushToken(deviceToken)
    }

    // Logs the open (or button tap) and opens the push's deep link. The system calls this on the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // UNNotificationResponse is not Sendable; it is only read on the main thread here.
        nonisolated(unsafe) let response = response
        MainActor.assumeIsolated { _ = Herald.shared.handleNotificationResponse(response) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Endpoint and app key from Base.xcconfig / Config.xcconfig, through Info.plist.
enum SampleConfig {
    static var endpoint: URL {
        let text = Bundle.main.object(forInfoDictionaryKey: "HeraldEndpoint") as? String ?? ""
        return URL(string: text) ?? URL(string: "http://localhost:3000")!
    }

    static var appKey: String {
        Bundle.main.object(forInfoDictionaryKey: "HeraldAppKey") as? String ?? ""
    }
}
