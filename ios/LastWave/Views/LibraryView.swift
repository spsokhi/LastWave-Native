import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library

    var body: some View {
        NavigationStack {
            List {
                if library.liked.isEmpty {
                    EmptyStateView(
                        symbol: "heart",
                        title: "No liked songs yet",
                        message: "Tap the heart on the player, or long-press any song and choose Like."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                player.play(library.liked)
                            } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            Button {
                                player.shuffle(library.liked)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .listRowBackground(Color.clear)
                    }
                    Section("\(library.liked.count) liked songs") {
                        ForEach(Array(library.liked.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track) { player.play(library.liked, startAt: index) }
                        }
                        .onDelete { offsets in
                            let tracks = offsets.map { library.liked[$0] }
                            tracks.forEach { library.toggleLike($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Library")
            .withMiniPlayer()
        }
    }
}
