import SwiftUI

@main
struct LastWaveApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var library = Library.shared
    @StateObject private var lastFm = LastFm.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(lastFm)
                .preferredColorScheme(.dark)
                .tint(.lwAccent)
        }
    }
}

extension Color {
    static let lwAccent = Color(red: 0xC6 / 255, green: 0xF1 / 255, blue: 0x00 / 255)
    static let lwBackground = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let lwSurface = Color(red: 0.12, green: 0.12, blue: 0.12)
}
