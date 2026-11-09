import HeraldSDK
import HeraldUI
import SwiftUI

struct HomeView: View {
    let lastDeepLink: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button {
                    Herald.shared.track("workout_completed", properties: ["minutes": 32])
                } label: {
                    Text("Log workout (32 min)").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if let lastDeepLink {
                    Text("Opened \(lastDeepLink.absoluteString)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                ContentCardFeed()
            }
            .navigationTitle("Lumen")
            .onAppear { Herald.shared.screen("Home") }
        }
    }
}
