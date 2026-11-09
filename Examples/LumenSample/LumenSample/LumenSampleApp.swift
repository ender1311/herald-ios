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
            #if DEBUG
            if let seconds = DebugLaunch.value("-LumenSessionTimeout").flatMap(TimeInterval.init) {
                options.sessionTimeout = seconds
            }
            #endif
        }
        Herald.useDefaultInAppUI(theme: HeraldTheme())
        UNUserNotificationCenter.current().delegate = self
        // Buttons for pushes whose payload sets `aps.category` to "workout_reminder".
        Herald.shared.registerPushCategories([
            HeraldPushCategory(id: "workout_reminder", buttons: [
                .init(id: "start", title: "Start workout"),
                .init(id: "later", title: "Later", opensApp: false),
            ]),
        ])
        #if DEBUG
        DebugLaunch.run()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Herald.shared.setPushToken(deviceToken)
    }

    // Logs the open (or button tap) and opens the push's deep link.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Herald.shared.handleNotificationResponse(response)
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

    /// Debug only: the identity token minted for the `-LumenUser` user (HERALD_USER_TOKEN).
    static var userToken: String? {
        (Bundle.main.object(forInfoDictionaryKey: "HeraldUserToken") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

#if DEBUG
/// Launch-argument hooks for end-to-end runs on a simulator, where nothing can be tapped:
/// `-LumenUser <id>` identifies the user with HERALD_USER_TOKEN, `-LumenLogWorkout 1` logs a workout,
/// `-LumenClickFirstCard 1` logs a click on the first card once cards arrive,
/// `-LumenSessionTimeout <seconds>` shortens the session so a relaunch starts a new one.
enum DebugLaunch {
    static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run() {
        if let userId = value("-LumenUser") {
            Herald.shared.identify(userId: userId, traits: ["plan": "free"])
            Herald.shared.setUserToken(SampleConfig.userToken)
        }
        if value("-LumenLogWorkout") != nil {
            Herald.shared.track("workout_completed", properties: ["minutes": 32])
        }
        if value("-LumenClickFirstCard") != nil {
            Task { @MainActor in
                for await cards in Herald.shared.contentCards.updates {
                    guard let card = cards.first else { continue }
                    Herald.shared.logClick(card)
                    Herald.shared.flush()
                    break
                }
            }
        }
    }
}
#endif
