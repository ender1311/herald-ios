import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case home, settings, preview }

    @State private var tab: Tab = .home
    @State private var lastDeepLink: URL?

    var body: some View {
        TabView(selection: $tab) {
            HomeView(lastDeepLink: lastDeepLink)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            #if DEBUG
            PreviewMessagesView()
                .tabItem { Label("Preview", systemImage: "eye") }
                .tag(Tab.preview)
            #endif
        }
        .onOpenURL { lastDeepLink = $0 }
        #if DEBUG
        .task {
            // `-HeraldPreview feed|slideup|modal|full|html` opens a preview directly (used for screenshots).
            guard let target = PreviewLaunch.target else { return }
            PreviewMessages.load()
            tab = target == "feed" ? .home : .preview
            if target != "feed" { await PreviewMessages.show(target) }
        }
        #endif
    }
}
