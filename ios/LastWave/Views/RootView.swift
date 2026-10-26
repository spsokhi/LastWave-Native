import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "heart.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(isPresented: $player.isNowPlayingPresented) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    /// Pins the mini player above the tab bar of a tab's content.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
    }
}
