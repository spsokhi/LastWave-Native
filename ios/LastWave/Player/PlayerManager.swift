import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: CaseIterable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Owns the AVPlayer, the play queue, lock-screen integration, lyrics for the
/// current song and Last.fm scrobble timing.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsLoading = false
    @Published private(set) var isFetchingRadio = false
    @Published var errorMessage: String?
    @Published var repeatMode: RepeatMode = .off
    @Published var isNowPlayingPresented = false
    @Published var autoplay: Bool {
        didSet { UserDefaults.standard.set(autoplay, forKey: "player.autoplay") }
    }

    var current: Track? {
        guard let index = currentIndex, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    private let player = AVPlayer()
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var controlStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var retriedCurrent = false
    /// Songs that failed back to back; auto-skip stops at `maxConsecutiveFailures`
    /// so a blocked network can't silently burn through the whole queue.
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3
    private var resumePosition: Double?
    private var pendingAdvance = false
    private var isSeeking = false

    // Scrobble rule: played for half the song or 4 minutes, whichever comes first.
    private var listenedSeconds: Double = 0
    private var lastTick: Double?
    private var trackStartedAt = Date()
    private var scrobbled = false

    private init() {
        autoplay = UserDefaults.standard.object(forKey: "player.autoplay") as? Bool ?? true
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
    }

    // MARK: - Public controls

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        cancelRadio()
        consecutiveFailures = 0
        queue = tracks
        load(index: index)
    }

    /// Plays a song and fills the queue with YouTube Music's radio for it.
    func playRadio(from track: Track) {
        cancelRadio()
        consecutiveFailures = 0
        queue = [track]
        load(index: 0)
        extendWithRadio(seed: track)
    }

    func shuffle(_ tracks: [Track]) {
        play(tracks.shuffled())
    }

    func playNext(_ track: Track) {
        guard let index = currentIndex else { return play([track]) }
        queue.insert(track, at: index + 1)
    }

    func addToQueue(_ track: Track) {
        guard currentIndex != nil else { return play([track]) }
        queue.append(track)
    }

    func removeFromQueue(at index: Int) {
        guard let current = currentIndex, index != current, queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if index < current { currentIndex = current - 1 }
    }

    func jump(to index: Int) {
        consecutiveFailures = 0
        load(index: index)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let index = currentIndex else { return }
        if player.currentItem == nil {
            if !isLoading { load(index: index) }
            return
        }
        activateSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            load(index: index + 1)
        } else if repeatMode == .all, !queue.isEmpty {
            load(index: 0)
        } else if autoplay, let track = current {
            pendingAdvance = true
            extendWithRadio(seed: track)
        }
    }

    func previous() {
        guard let index = currentIndex else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(index: index - 1)
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        isSeeking = true
        currentTime = target
        lastTick = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - Loading

    private func load(index: Int, isRetry: Bool = false) {
        guard queue.indices.contains(index) else { return }
        loadTask?.cancel()
        let track = queue[index]
        currentIndex = index
        pendingAdvance = false
        if !isRetry {
            retriedCurrent = false
            resumePosition = nil
        }

        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = resumePosition ?? 0
        duration = Double(track.durationSeconds ?? 0)
        isLoading = true
        errorMessage = nil

        if !isRetry {
            resetScrobbleState()
            loadArtwork(for: track)
            loadLyrics(for: track)
            Library.shared.recordPlay(track)
            LastFm.shared.updateNowPlaying(track)
        }
        updateNowPlayingInfo()

        loadTask = Task { [weak self] in
            do {
                if isRetry { await InnerTube.shared.invalidate(track.videoId) }
                let stream = try await InnerTube.shared.resolveStream(track.videoId)
                guard !Task.isCancelled else { return }
                self?.start(stream, for: track)
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleFailure(track: track, error: error)
            }
        }

        if index == queue.count - 1, autoplay, repeatMode == .off {
            extendWithRadio(seed: track)
        }
        prefetch(after: index)
    }

    private func start(_ stream: AudioStream, for track: Track) {
        guard current?.videoId == track.videoId else { return }
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, message: message, track: track) }
        }
        player.replaceCurrentItem(with: item)
        if let position = resumePosition, position > 1 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        resumePosition = nil
        activateSession()
        player.play()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, track: Track) {
        guard current?.videoId == track.videoId else { return }
        switch status {
        case .readyToPlay:
            isLoading = false
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            updateNowPlayingInfo()
        case .failed:
            handleFailure(track: track, error: InnerTubeError.unplayable(message ?? "Playback failed"))
        default:
            break
        }
    }

    private func handleFailure(track: Track, error: Error) {
        guard current?.videoId == track.videoId, let index = currentIndex else { return }
        // Expired or rejected URLs usually play after one fresh resolve.
        if !retriedCurrent {
            retriedCurrent = true
            resumePosition = currentTime > 1 ? currentTime : nil
            load(index: index, isRetry: true)
            return
        }
        isLoading = false
        isPlaying = false
        consecutiveFailures += 1
        errorMessage = "Couldn't play “\(track.title)”: \(error.localizedDescription)"
        if consecutiveFailures >= Self.maxConsecutiveFailures {
            errorMessage = "\(consecutiveFailures) songs in a row failed: \(error.localizedDescription)"
            return
        }
        if index + 1 < queue.count {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.current?.videoId == track.videoId else { return }
                self.next()
            }
        }
    }

    private func prefetch(after index: Int) {
        guard queue.indices.contains(index + 1) else { return }
        let nextId = queue[index + 1].videoId
        Task.detached(priority: .utility) {
            _ = try? await InnerTube.shared.resolveStream(nextId)
        }
    }

    // MARK: - Radio

    private func extendWithRadio(seed: Track) {
        guard radioTask == nil else { return }
        isFetchingRadio = true
        radioTask = Task { [weak self] in
            let tracks = (try? await InnerTube.shared.radio(for: seed.videoId)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.radioTask = nil
            self.isFetchingRadio = false
            let existing = Set(self.queue.map(\.videoId))
            let fresh = tracks.filter { !existing.contains($0.videoId) }
            guard !fresh.isEmpty else {
                self.pendingAdvance = false
                return
            }
            self.queue.append(contentsOf: fresh)
            if let index = self.currentIndex { self.prefetch(after: index) }
            if self.pendingAdvance {
                self.pendingAdvance = false
                self.next()
            }
        }
    }

    private func cancelRadio() {
        radioTask?.cancel()
        radioTask = nil
        isFetchingRadio = false
        pendingAdvance = false
    }

    // MARK: - Lyrics & artwork

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        lyrics = nil
        lyricsLoading = true
        lyricsTask = Task { [weak self] in
            let result = await LyricsService.fetch(for: track)
            guard !Task.isCancelled, let self, self.current?.videoId == track.videoId else { return }
            self.lyrics = result
            self.lyricsLoading = false
        }
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artwork = nil
        guard let url = track.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0),
                  !Task.isCancelled,
                  let self, self.current?.videoId == track.videoId else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }

        controlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.controlStatusChanged(status) }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in self?.itemFinished(item) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) else { return }
            Task { @MainActor in self?.resume() }
        })
    }

    private func controlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            isPlaying = true
            isLoading = false
            consecutiveFailures = 0
        case .waitingToPlayAtSpecifiedRate:
            isPlaying = true
        case .paused:
            isPlaying = false
        @unknown default:
            break
        }
        updateNowPlayingInfo()
    }

    private func tick(_ seconds: Double) {
        guard !isSeeking, player.currentItem != nil, seconds.isFinite else { return }
        currentTime = seconds
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        if isPlaying, let last = lastTick {
            let delta = seconds - last
            if delta > 0, delta < 2 { listenedSeconds += delta }
        }
        lastTick = seconds
        if !scrobbled, duration > 30, listenedSeconds >= min(duration / 2, 240), let track = current {
            scrobbled = true
            LastFm.shared.scrobble(track, startedAt: trackStartedAt)
        }
    }

    private func itemFinished(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        if repeatMode == .one {
            resetScrobbleState()
            seek(to: 0)
            player.play()
            return
        }
        if let index = currentIndex, index + 1 >= queue.count, repeatMode == .off, !autoplay {
            player.pause()
            seek(to: 0)
            return
        }
        next()
    }

    private func resetScrobbleState() {
        listenedSeconds = 0
        lastTick = nil
        scrobbled = false
        trackStartedAt = Date()
    }

    // MARK: - System integration

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
