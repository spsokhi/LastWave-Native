import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if library.recent.isEmpty {
                    EmptyStateView(
                        symbol: "waveform",
                        title: "Welcome to LastWave",
                        message: "Search for any song on YouTube Music. Playing one starts a radio of similar tracks."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    if let last = library.recent.first {
                        Section {
                            Button {
                                player.playRadio(from: last)
                            } label: {
                                HStack(spacing: 14) {
                                    ArtworkView(url: last.artworkURL, size: 64, cornerRadius: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Start a mix from")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(last.title).font(.headline).lineLimit(1)
                                        Text(last.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundStyle(Color.lwAccent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section("Recently played") {
                        ForEach(Array(library.recent.prefix(30).enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track) {
                                player.play(Array(library.recent.prefix(30)), startAt: index)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(greeting)
            .withMiniPlayer()
        }
    }
}
