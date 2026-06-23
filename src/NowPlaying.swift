import AppKit
import MediaPlayer

/// Broadcasts playback state to the macOS Now Playing system (Control Center,
/// menu bar widget) and handles hardware media keys / remote commands.
@MainActor
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()
    private var configured = false

    func setup() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            Task { @MainActor in if !Player.shared.isPlaying { Player.shared.togglePlay() } }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in if Player.shared.isPlaying { Player.shared.togglePlay() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in Player.shared.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in Player.shared.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in Player.shared.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                let duration = Player.shared.currentDuration
                if duration > 0 { Player.shared.seek(to: position / duration) }
            }
            return .success
        }
        update()
    }

    /// Pushes current track metadata + transport state. Control Center
    /// extrapolates elapsed time from the rate, so this only needs calling on
    /// state changes (track change, play/pause, seek), not on a timer.
    func update() {
        let player = Player.shared
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? "Unknown Artist" : track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: player.currentDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let image = Library.shared.artwork(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }
}
