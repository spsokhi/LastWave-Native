import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artworkURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("mini-title")
                        if let error = player.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .accessibilityIdentifier("mini-error")
                        } else {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Button { player.togglePlayPause() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                        }
                    }
                    .frame(width: 36, height: 36)
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.lwAccent)
                        .frame(width: geometry.size.width * progress)
                }
                .frame(height: 2)
            }
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { player.isNowPlayingPresented = true }
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime / player.duration, 0), 1))
    }
}
