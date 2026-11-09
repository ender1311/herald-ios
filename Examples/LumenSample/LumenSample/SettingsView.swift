import HeraldSDK
import SwiftUI

struct SettingsView: View {
    @State private var pushStatus = "Not requested"
    @State private var user = "Anonymous"

    var body: some View {
        NavigationStack {
            Form {
                Section("Push notifications") {
                    Button("Enable push notifications") {
                        Task {
                            let granted = await Herald.shared.requestPushAuthorization()
                            pushStatus = granted ? "Allowed" : "Not allowed"
                        }
                    }
                    LabeledContent("Status", value: pushStatus)
                }
                Section("User") {
                    LabeledContent("Current user", value: user)
                    Button("Identify u_demo") {
                        Herald.shared.identify(userId: "u_demo", traits: ["plan": "free"])
                        user = "u_demo"
                    }
                    Button("Reset", role: .destructive) {
                        Herald.shared.reset()
                        user = "Anonymous"
                    }
                }
                Section("Herald") {
                    LabeledContent("Endpoint", value: SampleConfig.endpoint.absoluteString)
                    LabeledContent("SDK", value: Herald.sdkVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
