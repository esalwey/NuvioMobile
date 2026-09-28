import Foundation
import SharedCore

/// Engine-agnostic watch-progress + Trakt scrobbling for a `PlaybackContext`. Mirrors the logic in
/// `MPVTVPlayerViewController` exactly so both engines record identically; the native AVPlayer path
/// (Phase 3) uses it. The mpv controller can be migrated onto this later — it still has its own copy
/// for now to avoid touching the shipping player. See docs/tvos-hybrid-player-plan.md.
@MainActor
final class PlaybackProgressRecorder {
    private let context: PlaybackContext

    init(context: PlaybackContext) { self.context = context }

    // MARK: - Resume

    /// Saved resume position in seconds — only if >10s in and not completed (mirrors MPV's gate).
    func resumePositionSec() -> Double? {
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        ), !entry.isCompleted else { return nil }
        let seconds = Double(entry.lastPositionMs) / 1000.0
        return seconds > 10 ? seconds : nil
    }

    // MARK: - Progress save

    // CW-1: filed under the SERIES name with the episode's own name/still beside it (mobile
    // parity) — `context.title` is the "S1E3 · Pilot" picker label, which Continue Watching, the
    // hero and the synced record used to show as the show's title.
    private lazy var session = WatchProgressPlaybackSession(
        profileId: ActiveProfileProvider.shared.activeProfileId,
        contentType: context.contentType,
        parentMetaId: context.parentMetaId,
        parentMetaType: context.contentType,
        videoId: context.videoId,
        title: context.progressTitle,
        logo: context.logo,
        poster: context.poster,
        background: context.background,
        seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
        episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
        episodeTitle: context.episodeTitle,
        episodeThumbnail: context.episodeStill,
        providerName: context.providerName,
        providerAddonId: context.providerAddonId,
        lastStreamTitle: context.streamTitle,
        lastStreamSubtitle: context.streamSubtitle,
        pauseDescription: context.synopsis,
        lastSourceUrl: context.url.absoluteString
    )

    /// Record playback progress. `flush` forces an immediate write (use on teardown). `isEnded`
    /// records the entry as completed regardless of the watched fraction — the end of the file,
    /// or an Up Next hand-off during the credits — so Continue Watching moves on to the next one.
    func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool,
                isEnded: Bool = false) {
        guard durationSec > 0, positionSec > 1 else { return }
        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !isPaused,
            isEnded: isEnded,
            durationMs: Int64(durationSec * 1000),
            positionMs: Int64(positionSec * 1000),
            bufferedPositionMs: Int64(positionSec * 1000),
            playbackSpeed: Float(speed),
            videoWidth: 0,
            videoHeight: 0
        )
        if flush {
            // PLY-4: the terminal write reaches the Nuvio account (mobile `flushWatchProgress`
            // parity) — and, through the shared completion cascade, marks a finished episode
            // watched there too. The 3 s ticks below stay local; the push is deduplicated.
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: true)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    // MARK: - Trakt scrobbling

    private var traktItem: TraktScrobbleItem?
    private var traktRequested = false
    private var traktClosed = false

    func startTrakt(positionSec: Double, durationSec: Double) {
        guard !traktRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) { return }
        traktRequested = true
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.progressTitle,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: context.episodeTitle,
            releaseInfo: nil
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, let item, !self.traktClosed else { return }
                self.traktItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: Self.percent(positionSec, durationSec)
                ) { _ in }
            }
        }
    }

    /// A new viewing on this recorder ("Play Again" after the session was stopped): the next
    /// `startTrakt` opens a fresh scrobble instead of being ignored as a repeat.
    func reopenTrakt() {
        traktItem = nil
        traktRequested = false
        traktClosed = false
    }

    func stopTrakt(positionSec: Double, durationSec: Double) {
        traktClosed = true
        guard let item = traktItem else { return }
        traktItem = nil
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: short ? 0 : Self.percent(positionSec, durationSec)
        ) { _ in }
    }

    private static func percent(_ positionSec: Double, _ durationSec: Double) -> Float {
        guard durationSec > 0 else { return 0 }
        return Float(min(100, max(0, positionSec / durationSec * 100)))
    }
}
