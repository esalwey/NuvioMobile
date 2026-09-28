package com.nuvio.app.features.tracking

import co.touchlab.kermit.Logger
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.supervisorScope

data class TrackingScrobbleFailure(
    val providerId: TrackingProviderId,
    val cause: Throwable,
)

/**
 * Trackers the tvOS players scrobble directly rather than through [TrackingScrobbleCoordinator]:
 * Trakt keeps its own `TraktScrobbleRepository.buildItem` + `scrobbleStart`/`scrobbleStop` path
 * (episode mapping, dedupe window, stop retries), so the coordinator must never scrobble it a
 * second time.
 */
val DirectPathScrobbleProviderIds: Set<TrackingProviderId> = setOf(TrackingProviderId.TRAKT)

/** [scrobblers] minus the ones the players scrobble directly ([DirectPathScrobbleProviderIds]). */
fun otherTrackerScrobblers(scrobblers: Collection<TrackingScrobbler>): List<TrackingScrobbler> =
    scrobblers.filterNot { scrobbler -> scrobbler.providerId in DirectPathScrobbleProviderIds }

/**
 * The event [TrackingScrobbleCoordinator.scrobbleOtherTrackers] sends, or null when the title has
 * nothing a tracker could match (no external id and no title). Built from the playback context
 * alone, so it does not depend on Trakt being able to address the title: a `kitsu:`/`mal:` id,
 * which Trakt's item build rejects, still reaches Simkl.
 */
fun buildOtherTrackerScrobbleEvent(
    contentType: String,
    parentMetaId: String,
    videoId: String?,
    title: String?,
    seasonNumber: Int?,
    episodeNumber: Int?,
    episodeTitle: String?,
    progressPercent: Double,
): TrackingScrobbleEvent? {
    val media = buildTrackingMediaReference(
        contentType = contentType,
        parentMetaId = parentMetaId,
        videoId = videoId,
        title = title,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
        episodeTitle = episodeTitle,
    )
    if (!media.hasResolvableIdentity) return null
    return TrackingScrobbleEvent(
        media = media,
        progressPercent = progressPercent.takeIf(Double::isFinite)?.coerceIn(0.0, 100.0) ?: 0.0,
    )
}

object TrackingScrobbleCoordinator {
    private val log = Logger.withTag("TrackingScrobble")

    suspend fun scrobble(
        profileId: Int,
        action: TrackingScrobbleAction,
        event: TrackingScrobbleEvent,
    ): List<TrackingScrobbleFailure> {
        if (profileId != ProfileRepository.activeProfileId) return emptyList()
        TrackingProviderRegistry.ensureLoaded()
        val failures = dispatchTrackingScrobble(
            scrobblers = TrackingProviderRegistry.connectedScrobblers(),
            profileId = profileId,
            action = action,
            event = event,
        )
        failures.forEach { failure ->
            log.w(failure.cause) {
                "${failure.providerId.storageId} scrobble ${action.wireValue} failed"
            }
        }
        return failures
    }

    /**
     * CW sync (REMAINING_FIX #1): the tvOS players' scrobble for every connected tracker except
     * the ones they scrobble directly ([DirectPathScrobbleProviderIds], i.e. Trakt) — today that is
     * Simkl, which the players never reached before, so with Simkl as the Watch Progress Source a
     * whole autoplay chain left Continue Watching on the episode Simkl last knew about.
     *
     * Called from Swift with the raw playback context, so it builds the tracker-neutral media
     * reference itself ([buildOtherTrackerScrobbleEvent]) and is independent of Trakt's item build.
     * A STOP reaches `SimklMutationRepository.scrobble`, which commits the result into the Simkl
     * snapshot (watched at ≥ 80 %, a paused session below), and that republishes Continue Watching.
     *
     * Never throws anything but cancellation: each scrobbler's failure (offline, HTTP error, and the
     * `require(...)` checks of `SimklMutationService.scrobble`) is caught per scrobbler by
     * [dispatchTrackingScrobble] and logged here, and anything else is logged too — an exception
     * escaping a Kotlin suspend function into Swift aborts the app.
     */
    suspend fun scrobbleOtherTrackers(
        profileId: Int,
        action: TrackingScrobbleAction,
        contentType: String,
        parentMetaId: String,
        videoId: String?,
        title: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeTitle: String?,
        progressPercent: Double,
    ) {
        try {
            if (profileId != ProfileRepository.activeProfileId) return
            // Idempotent: Simkl's scrobbler registers itself on first access, which must not depend
            // on some other repository having touched it first.
            ensureTrackingProvidersRegistered()
            TrackingProviderRegistry.ensureLoaded()
            val scrobblers = otherTrackerScrobblers(TrackingProviderRegistry.connectedScrobblers())
            if (scrobblers.isEmpty()) return
            val event = buildOtherTrackerScrobbleEvent(
                contentType = contentType,
                parentMetaId = parentMetaId,
                videoId = videoId,
                title = title,
                seasonNumber = seasonNumber,
                episodeNumber = episodeNumber,
                episodeTitle = episodeTitle,
                progressPercent = progressPercent,
            ) ?: run {
                log.d { "Skipped ${action.wireValue} scrobble for $parentMetaId: no id or title to match" }
                return
            }
            val failures = dispatchTrackingScrobble(
                scrobblers = scrobblers,
                profileId = profileId,
                action = action,
                event = event,
            )
            failures.forEach { failure ->
                log.w(failure.cause) {
                    "${failure.providerId.storageId} scrobble ${action.wireValue} failed for $parentMetaId " +
                        "(${seasonNumber ?: "-"}x${episodeNumber ?: "-"}) at ${event.progressPercent}%"
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Scrobble ${action.wireValue} to the other trackers failed for $parentMetaId" }
        }
    }

    suspend fun scrobbleSeek(
        profileId: Int,
        action: TrackingScrobbleAction,
        event: TrackingScrobbleEvent,
    ): List<TrackingScrobbleFailure> {
        if (profileId != ProfileRepository.activeProfileId) return emptyList()
        TrackingProviderRegistry.ensureLoaded()
        val failures = dispatchTrackingSeekScrobble(
            scrobblers = TrackingProviderRegistry.connectedScrobblers(),
            profileId = profileId,
            action = action,
            event = event,
        )
        failures.forEach { failure ->
            log.w(failure.cause) {
                "${failure.providerId.storageId} seek scrobble ${action.wireValue} failed"
            }
        }
        return failures
    }
}

// Fork: public (upstream: internal) — shared tests consume these cross-module.
suspend fun dispatchTrackingSeekScrobble(
    scrobblers: Collection<TrackingScrobbler>,
    profileId: Int,
    action: TrackingScrobbleAction,
    event: TrackingScrobbleEvent,
): List<TrackingScrobbleFailure> = dispatchTrackingScrobble(
    scrobblers = scrobblers.filter { scrobbler ->
        scrobbler.seekScrobblePolicy == TrackingSeekScrobblePolicy.STOP_AND_RESTART
    },
    profileId = profileId,
    action = action,
    event = event,
)

suspend fun dispatchTrackingScrobble(
    scrobblers: Collection<TrackingScrobbler>,
    profileId: Int,
    action: TrackingScrobbleAction,
    event: TrackingScrobbleEvent,
): List<TrackingScrobbleFailure> = supervisorScope {
    scrobblers.map { scrobbler ->
        async {
            try {
                scrobbler.scrobble(profileId = profileId, action = action, event = event)
                null
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                TrackingScrobbleFailure(providerId = scrobbler.providerId, cause = error)
            }
        }
    }.awaitAll().filterNotNull()
}
