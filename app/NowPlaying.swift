import MediaPlayer

// System Now Playing + remote commands (Control Centre, media keys, headset). Commands are
// registered once; info is refreshed from the model each tick.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onToggle: () -> Void = {}
    var onSkip: (Bool) -> Void = { _ in }      // true = forward
    var onSeek: (Double) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrev: () -> Void = {}
    private var wired = false

    func setupCommands() {
        guard !wired else { return }; wired = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.onPlay(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.onPause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle(); return .success }
        setSkipIntervals()
        c.skipForwardCommand.addTarget { [weak self] _ in self?.onSkip(true); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.onSkip(false); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let p = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime { self?.onSeek(p) }
            return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.onNext(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.onPrev(); return .success }
    }

    /// The intervals Control Centre shows on its skip buttons (follow the Settings values).
    func setSkipIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Settings.skipForward)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Settings.skipBackward)]
    }

    func update(title: String, duration: Double, position: Double, rate: Double, paused: Bool) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : rate,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
