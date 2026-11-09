import AVFoundation
import Observation

/// Plays a song straight off the iPod, to hear it before exporting or deleting it.
@MainActor @Observable
final class Preview {
    private(set) var track: PodTrack?
    private(set) var playing = false
    /// Seconds into the song.
    private(set) var position: Double = 0

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { if time.seconds.isFinite { self?.position = time.seconds } }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.stop()
            }
        }
    }

    func isPlaying(_ t: PodTrack) -> Bool { playing && track?.id == t.id }

    func play(_ t: PodTrack) {
        guard t.exists else { return }
        if track?.id != t.id {
            player.replaceCurrentItem(with: AVPlayerItem(url: t.fileURL))
            track = t
            position = 0
        }
        player.play()
        playing = true
    }

    /// Plays the song, or pauses it if it's the one playing.
    func toggle(_ t: PodTrack) {
        if isPlaying(t) { pause() } else { play(t) }
    }

    func pause() {
        player.pause()
        playing = false
    }

    /// Lets go of the file too, which the iPod needs before it can eject.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        track = nil
        playing = false
        position = 0
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
}
