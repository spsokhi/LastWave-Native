import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.lwSurface
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct TrackRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    let track: Track
    let onTap: () -> Void

    private var isCurrent: Bool { player.current?.videoId == track.videoId }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkURL, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isCurrent ? Color.lwAccent : .primary)
                        .lineLimit(1)
                    Text([track.artist, track.album].compactMap { $0 }.joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent && player.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.lwAccent)
                } else if let duration = track.durationText {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.playNext(track) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
            Button { player.playRadio(from: track) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
            Button { library.toggleLike(track) } label: {
                library.isLiked(track)
                    ? Label("Remove from liked", systemImage: "heart.slash")
                    : Label("Like", systemImage: "heart")
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(Color.lwAccent)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
