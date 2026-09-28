package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.details.SeriesPrimaryAction
import com.nuvio.app.features.details.seriesPrimaryAction
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.normalizeWatchedMarkedAtEpochMs
import com.nuvio.app.features.watching.domain.WatchingContentRef
import com.nuvio.app.features.watching.domain.WatchingProgressRecord
import com.nuvio.app.features.watching.domain.WatchingWatchedRecord
import com.nuvio.app.features.watching.domain.latestCompletedSeriesEpisode
import kotlinx.coroutines.CancellationException

/*
 * tvOS Continue Watching "Up Next" (CW-2) — the shared half of mobile HomeScreen's next-up
 * pipeline (`buildHomeNextUpSeedCandidates`, `resolveHomeNextUpCandidate`,
 * `buildHomeContinueWatchingItems`), reduced to what the tvOS row needs. A series whose latest
 * watched episode is finished leaves the in-progress row (`continueWatchingEntries` drops it); its
 * NEXT released episode comes back as an Up Next card instead of the show vanishing after a binge.
 *
 * The tvOS row is a list of `WatchProgressEntry`, so an Up Next card is a synthetic entry for the
 * next episode (no position, `source = WatchProgressSourceNextUp`) — never written to the
 * repository: it only drives the row, the hero and the stream picker, and the episode's own
 * playback then records real progress under the same `parent:season:episode` key.
 *
 * Deliberate differences from mobile: unaired next episodes are never surfaced (the tvOS Home has
 * a dedicated Upcoming row for those), and there is no release-alert sort or enrichment cache.
 */

/** `WatchProgressEntry.source` of a Continue Watching Up Next card (see the file comment). */
const val WatchProgressSourceNextUp = "next_up"

/** A series whose latest watched episode is finished: what its Up Next card is resolved from. */
data class ContinueWatchingNextUpSeed(
    val contentId: String,
    val contentType: String,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val markedAtEpochMs: Long,
) {
    /** Mobile's dismiss key: a dismissed card stays hidden until another episode is finished. */
    val dismissKey: String
        get() = nextUpDismissKey(contentId, seasonNumber, episodeNumber)
}

/** The outcome of resolving one seed. */
data class ContinueWatchingNextUpResolution(
    /** The Up Next card, or null when the series has nothing to continue with right now. */
    val entry: WatchProgressEntry?,
    /** False when the series metadata could not be fetched (offline, add-on down): retry later. */
    val isConclusive: Boolean,
)

/**
 * Seeds for the row (mobile `buildHomeNextUpSeedCandidates` + its in-progress suppression): the
 * latest finished main-season episode per series — progress entries the active provider accepts as
 * next-up seeds, plus explicit episode marks unless the provider owns completed history — minus
 * series whose in-progress card is at least as recent, hidden/dropped shows, dismissed cards and
 * seeds older than the provider's Continue Watching window. Most recent first, one per series.
 */
fun buildContinueWatchingNextUpSeeds(
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    inProgressEntries: List<WatchProgressEntry>,
    preferFurthestEpisode: Boolean,
    dismissedNextUpKeys: Set<String>,
    recencyCutoffEpochMs: Long?,
    limit: Int,
    shouldUseProgressSeed: (WatchProgressEntry) -> Boolean = { entry ->
        entry.shouldUseAsCompletedSeedForContinueWatching()
    },
    isContentHidden: (String) -> Boolean = { false },
): List<ContinueWatchingNextUpSeed> {
    val progressSeeds = progressEntries.filter { entry ->
        entry.parentMetaType.isSeriesTypeForContinueWatching() &&
            entry.seasonNumber != null && entry.episodeNumber != null && entry.seasonNumber != 0 &&
            !isMalformedNextUpSeedContentId(entry.parentMetaId) &&
            !isContentHidden(entry.parentMetaId) &&
            shouldUseProgressSeed(entry)
    }
    val watchedSeeds = watchedItems.filter { item ->
        item.type.isSeriesTypeForContinueWatching() &&
            item.season != null && item.episode != null && item.season != 0 &&
            !isMalformedNextUpSeedContentId(item.id) &&
            !isContentHidden(item.id)
    }
    val contents = buildSet {
        progressSeeds.forEach { entry -> add(WatchingContentRef(type = entry.parentMetaType, id = entry.parentMetaId)) }
        watchedSeeds.forEach { item -> add(WatchingContentRef(type = item.type, id = item.id)) }
    }
    val progressRecords = progressSeeds.map { entry ->
        val normalized = entry.normalizedCompletion()
        WatchingProgressRecord(
            content = WatchingContentRef(type = normalized.parentMetaType, id = normalized.parentMetaId),
            videoId = normalized.videoId,
            seasonNumber = normalized.seasonNumber,
            episodeNumber = normalized.episodeNumber,
            lastUpdatedEpochMs = normalized.lastUpdatedEpochMs,
            lastPositionMs = normalized.lastPositionMs,
            isCompleted = normalized.isEffectivelyCompleted,
        )
    }
    val watchedRecords = watchedSeeds.map { item ->
        WatchingWatchedRecord(
            content = WatchingContentRef(type = item.type, id = item.id),
            seasonNumber = item.season,
            episodeNumber = item.episode,
            markedAtEpochMs = normalizeWatchedMarkedAtEpochMs(item.markedAtEpochMs),
        )
    }
    // Each series only scans its own records: the row is rebuilt on every progress emission —
    // playback ticks included — and a profile can hold thousands of imported episode marks.
    val progressRecordsByContent = progressRecords.groupBy { record -> record.content }
    val watchedRecordsByContent = watchedRecords.groupBy { record -> record.content }
    // An in-progress card at least as recent as the series' last finished episode wins.
    val inProgressAtBySeries = inProgressEntries
        .filter { entry -> entry.parentMetaType.isSeriesTypeForContinueWatching() }
        .groupBy { entry -> entry.parentMetaId.trim() }
        .mapValues { (_, entries) -> entries.maxOf { entry -> entry.lastUpdatedEpochMs } }

    return contents
        .mapNotNull { content ->
            val completed = latestCompletedSeriesEpisode(
                content = content,
                progressRecords = progressRecordsByContent[content].orEmpty(),
                watchedRecords = watchedRecordsByContent[content].orEmpty(),
                preferFurthestEpisode = preferFurthestEpisode,
            ) ?: return@mapNotNull null
            if (completed.seasonNumber == 0) return@mapNotNull null
            val inProgressAt = inProgressAtBySeries[content.id.trim()]
            if (inProgressAt != null && inProgressAt >= completed.markedAtEpochMs) return@mapNotNull null
            ContinueWatchingNextUpSeed(
                contentId = content.id,
                contentType = content.type,
                seasonNumber = completed.seasonNumber,
                episodeNumber = completed.episodeNumber,
                markedAtEpochMs = completed.markedAtEpochMs,
            )
        }
        .filter { seed -> recencyCutoffEpochMs == null || seed.markedAtEpochMs >= recencyCutoffEpochMs }
        .filter { seed -> seed.dismissKey !in dismissedNextUpKeys }
        .sortedWith(
            compareByDescending<ContinueWatchingNextUpSeed> { seed -> seed.markedAtEpochMs }
                .thenByDescending { seed -> seed.seasonNumber }
                .thenByDescending { seed -> seed.episodeNumber },
        )
        // The same series filed under two type aliases ("series"/"tv") yields one card.
        .distinctBy { seed -> seed.contentId.trim() }
        .take(limit)
}

/**
 * The Up Next card for [seed] from its series' metadata (mobile `resolveHomeNextUpCandidate`): the
 * series primary action — resume beats next-up, only released episodes, no rewatch — when it is a
 * next episode, as a synthetic row entry. Null when there is nothing to continue with.
 */
fun MetaDetails.continueWatchingNextUpEntry(
    seed: ContinueWatchingNextUpSeed,
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    todayIsoDate: String,
    preferFurthestEpisode: Boolean,
): WatchProgressEntry? {
    val action = seriesPrimaryAction(
        content = WatchingContentRef(type = seed.contentType, id = seed.contentId),
        entries = progressEntries,
        watchedItems = watchedItems,
        todayIsoDate = todayIsoDate,
        preferFurthestEpisode = preferFurthestEpisode,
        showUnairedNextUp = false,
        allowRewatch = false,
    ) ?: return null
    // A resume point is the in-progress card's job, not an Up Next one.
    if (action.resumePositionMs != null) return null
    val next = videoForNextUpAction(action) ?: return null
    return WatchProgressEntry(
        contentType = seed.contentType,
        parentMetaId = seed.contentId,
        parentMetaType = seed.contentType,
        // The tvOS progress key (`parent:season:episode`, as the episode shelf and the next-episode
        // engine launch it), so this episode's playback records under the same key.
        videoId = buildPlaybackVideoId(
            parentMetaId = seed.contentId,
            seasonNumber = next.season,
            episodeNumber = next.episode,
            fallbackVideoId = next.id,
        ),
        title = name,
        logo = logo?.takeIf(String::isNotBlank),
        poster = poster?.takeIf(String::isNotBlank),
        background = background?.takeIf(String::isNotBlank),
        seasonNumber = next.season,
        episodeNumber = next.episode,
        episodeTitle = next.title.takeIf(String::isNotBlank),
        episodeThumbnail = next.thumbnail?.takeIf(String::isNotBlank),
        lastPositionMs = 0L,
        durationMs = 0L,
        // Sorted where the finished episode was: the card sits where the show left the row.
        lastUpdatedEpochMs = seed.markedAtEpochMs,
        pauseDescription = next.overview?.takeIf(String::isNotBlank),
        isCompleted = false,
        source = WatchProgressSourceNextUp,
    )
}

private fun MetaDetails.videoForNextUpAction(action: SeriesPrimaryAction): MetaVideo? {
    val season = action.seasonNumber
    val episode = action.episodeNumber
    if (season != null && episode != null) {
        videos.firstOrNull { video -> video.season == season && video.episode == episode }?.let { return it }
    }
    return videos.firstOrNull { video ->
        video.id == action.videoId ||
            buildPlaybackVideoId(
                parentMetaId = id,
                seasonNumber = video.season,
                episodeNumber = video.episode,
                fallbackVideoId = video.id,
            ) == action.videoId
    }
}

/**
 * The row: in-progress entries and Up Next cards, most recent first, one card per title — the
 * in-progress one wins a tie (mobile `buildHomeContinueWatchingItems`).
 */
fun mergeContinueWatchingNextUp(
    inProgressEntries: List<WatchProgressEntry>,
    nextUpEntries: List<WatchProgressEntry>,
): List<WatchProgressEntry> {
    if (nextUpEntries.isEmpty()) return inProgressEntries
    val seen = mutableSetOf<String>()
    return (inProgressEntries.map { entry -> entry to true } + nextUpEntries.map { entry -> entry to false })
        .sortedWith(
            compareByDescending<Pair<WatchProgressEntry, Boolean>> { (entry, _) -> entry.lastUpdatedEpochMs }
                .thenByDescending { (_, isProgress) -> isProgress },
        )
        .map { (entry, _) -> entry }
        .filter { entry -> seen.add(entry.parentMetaId.trim().ifBlank { entry.videoId }) }
}

/** Swift-facing entry points over the active profile's live state (see the file comment). */
object ContinueWatchingNextUp {
    /**
     * Seeds for the row given its current in-progress entries (`continueWatchingRow`), with the
     * active provider's seams applied: its next-up seed rule, hidden/dropped shows, its Continue
     * Watching window, and whether explicit episode marks count (not when it owns the history).
     */
    fun seeds(
        watchedItems: List<WatchedItem>,
        inProgressEntries: List<WatchProgressEntry>,
        preferFurthestEpisode: Boolean,
        dismissedNextUpKeys: Set<String>,
        limit: Int,
    ): List<ContinueWatchingNextUpSeed> {
        WatchProgressRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        val state = WatchProgressRepository.uiState.value
        val nowEpochMs = WatchProgressClock.nowEpochMs()
        return buildContinueWatchingNextUpSeeds(
            progressEntries = state.entries,
            watchedItems = if (WatchProgressRepository.activeProviderOwnsCompletedHistoryProjection()) {
                emptyList()
            } else {
                watchedItems
            },
            inProgressEntries = inProgressEntries,
            preferFurthestEpisode = preferFurthestEpisode,
            dismissedNextUpKeys = dismissedNextUpKeys,
            recencyCutoffEpochMs = WatchProgressRepository.activeProviderContinueWatchingCutoffEpochMs(
                daysCap = TraktSettingsRepository.uiState.value.continueWatchingDaysCap,
                nowEpochMs = nowEpochMs,
            ),
            limit = limit,
            shouldUseProgressSeed = { entry -> WatchProgressRepository.shouldUseAsNextUpSeed(entry, nowEpochMs) },
            isContentHidden = { contentId ->
                contentId in state.hiddenContentIds || WatchProgressRepository.isDroppedShow(contentId)
            },
        )
    }

    /**
     * Resolves [seed]'s Up Next card: the series meta (cache-first), the active provider's episode
     * numbering, then [continueWatchingNextUpEntry]. Never throws — a failure is a non-conclusive
     * resolution the caller may retry.
     */
    suspend fun resolveCard(
        seed: ContinueWatchingNextUpSeed,
        watchedItems: List<WatchedItem>,
        todayIsoDate: String,
        preferFurthestEpisode: Boolean,
    ): ContinueWatchingNextUpResolution = try {
        val meta = MetaDetailsRepository.fetch(type = seed.contentType, id = seed.contentId)
        if (meta == null) {
            ContinueWatchingNextUpResolution(entry = null, isConclusive = false)
        } else {
            val entries = WatchProgressRepository.prepareNextUpProgressEntries(
                entries = WatchProgressRepository.uiState.value.entries,
                contentId = seed.contentId,
            )
            ContinueWatchingNextUpResolution(
                entry = meta.continueWatchingNextUpEntry(
                    seed = seed,
                    progressEntries = entries,
                    watchedItems = if (WatchProgressRepository.activeProviderOwnsCompletedHistoryProjection()) {
                        emptyList()
                    } else {
                        watchedItems
                    },
                    todayIsoDate = todayIsoDate,
                    preferFurthestEpisode = preferFurthestEpisode,
                ),
                isConclusive = true,
            )
        }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        ContinueWatchingNextUpResolution(entry = null, isConclusive = false)
    }
}
