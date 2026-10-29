import SwiftUI

struct NowPlayingView: View {
    private enum Panel { case artwork, lyrics, queue }

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @State private var panel: Panel = .artwork
    @State private var scrubPosition: Double?

    var body: some View {
        Group {
            if let track = player.current {
                VStack(spacing: 20) {
                    Group {
                        switch panel {
                        case .artwork:
                            // Largest square that fits the space left above the controls.
                            GeometryReader { geometry in
                                let side = max(0, min(geometry.size.width, geometry.size.height, 420))
                                ArtworkView(url: track.artworkURL, size: side, cornerRadius: 14)
                                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        case .lyrics:
                            LyricsPanel()
                        case .queue:
                            QueuePanel()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    titleRow(track)
                    scrubber
                    transport
                    panelPicker
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 12)
            } else {
                EmptyStateView(symbol: "music.note", title: "Nothing playing", message: "Pick a song to start listening.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // As a background (not a ZStack sibling) the oversized, scaled-to-fill
        // blurred artwork can never widen the layout of the controls.
        .background { background }
    }

    private var background: some View {
        ZStack {
            Color.lwBackground
            AsyncImage(url: player.current?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .blur(radius: 60)
            .opacity(0.45)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(track.artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                library.toggleLike(track)
            } label: {
                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(library.isLiked(track) ? Color.lwAccent : .primary)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let position = scrubPosition {
                        player.seek(to: position)
                        scrubPosition = nil
                    }
                }
            )
            HStack {
                Text(formatTime(scrubPosition ?? player.currentTime))
                    .accessibilityIdentifier("elapsed-time")
                Spacer()
                if let error = player.errorMessage {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                        .accessibilityIdentifier("player-error")
                }
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            Button {
                player.autoplay.toggle()
            } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(player.autoplay ? Color.lwAccent : .secondary)
            }
            .accessibilityLabel("Autoplay similar songs")
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.lwAccent).frame(width: 72, height: 72)
                    if player.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.black)
                    }
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            Spacer()
            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.lwAccent)
            }
            .accessibilityLabel("Repeat")
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var panelPicker: some View {
        HStack {
            panelButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
            Spacer()
            panelButton(.queue, symbol: "list.bullet", label: "Up next")
        }
        .padding(.horizontal, 32)
    }

    private func panelButton(_ target: Panel, symbol: String, label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                panel = panel == target ? .artwork : target
            }
        } label: {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(panel == target ? Color.lwAccent : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct LyricsPanel: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Group {
            if player.lyricsLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = player.lyrics, !lyrics.synced.isEmpty {
                SyncedLyricsView(lyrics: lyrics)
            } else if let plain = player.lyrics?.plain, !plain.isEmpty {
                ScrollView {
                    Text(plain)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                EmptyStateView(symbol: "quote.bubble", title: "No lyrics found", message: "LRCLIB has no lyrics for this song yet.")
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct SyncedLyricsView: View {
    @EnvironmentObject private var player: PlayerManager
    let lyrics: Lyrics

    var body: some View {
        let active = lyrics.activeIndex(at: player.currentTime + 0.2)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.synced) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(line.id == active ? Color.primary : Color.secondary.opacity(0.55))
                            .scaleEffect(line.id == active ? 1.0 : 0.96, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .onTapGesture { player.seek(to: line.time) }
                    }
                }
                .padding(.vertical, 120)
                .animation(.easeOut(duration: 0.25), value: active)
            }
            .onChange(of: active) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: .center) }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.15),
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct QueuePanel: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                    Button {
                        player.jump(to: index)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: track.artworkURL, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(index == player.currentIndex ? Color.lwAccent : .primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if index == player.currentIndex {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.lwAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .id(index)
                    .deleteDisabled(index == player.currentIndex)
                }
                .onDelete { offsets in
                    offsets.sorted(by: >).forEach { player.removeFromQueue(at: $0) }
                }
                if player.isFetchingRadio {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Finding similar songs…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let index = player.currentIndex { proxy.scrollTo(index, anchor: .top) }
            }
        }
    }
}
