import AVFoundation
import MediaPlayer
import Observation

/// Plays a lecture's audio with speed control, and shows it on the Lock Screen and in Control
/// Center so you can listen with the phone in your pocket.
@MainActor
@Observable
final class LecturePlayer {
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var subtitle = ""

    func load(url: URL, title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isReady = player.duration > 0
        } catch {
            isReady = false
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        try? AudioSessionController.activateForPlayback()
        player.rate = rate
        player.play()
        isPlaying = true
        startTicking()
        setUpRemoteCommands()
        updateNowPlaying()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        currentTime = player.currentTime
        tickTask?.cancel()
        updateNowPlaying()
    }

    func play(from time: TimeInterval) {
        seek(to: time)
        if !isPlaying {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
        updateNowPlaying()
    }

    /// Stops playback and releases the audio session and Lock Screen controls.
    func teardown() {
        tickTask?.cancel()
        tickTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isReady = false
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AudioSessionController.deactivate()
    }

    // MARK: Private

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if isPlaying, !player.isPlaying {
            // Reached the end, or another app (e.g. a call) took over the audio.
            isPlaying = false
            tickTask?.cancel()
            updateNowPlaying()
        }
    }

    private func setUpRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        // Remote commands arrive on the main thread.
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayback() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        let forwardTarget = center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        let backwardTarget = center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -15) }
            return .success
        }
        let scrubTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }

        remoteTargets = [
            (center.playCommand, playTarget),
            (center.pauseCommand, pauseTarget),
            (center.togglePlayPauseCommand, toggleTarget),
            (center.skipForwardCommand, forwardTarget),
            (center.skipBackwardCommand, backwardTarget),
            (center.changePlaybackPositionCommand, scrubTarget)
        ]
    }

    private func removeRemoteCommands() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
        }
        remoteTargets.removeAll()
    }

    private func updateNowPlaying() {
        guard player != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0
        ]
        if !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
