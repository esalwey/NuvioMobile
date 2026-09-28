package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.watching.domain.isSeriesLikeWatchingContentType
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * CW alias fix (REMAINING_FIX #2): the IMDb id Continue Watching groups a series under, for
 * display only.
 *
 * The same show can be stored under two ids. The details page and its episode list write under
 * the resolved meta id, and `tmdb:` only becomes `tt…` when a TMDB key is set and the lookup
 * answers in time. So one launch writes `tmdb:1396_s1e1`, a later one `tt0903747_s1e5`. Grouped
 * by the raw id, those are two series: two cards that look the same, and the one not launched
 * never moves.
 *
 * This map only changes how the row groups and deduplicates. No stored `parentMetaId` or progress
 * key is ever rewritten: the server, the other devices and the details page keep seeing the ids
 * that were written, and a card still launches under its own id.
 *
 * Fed from series metadata, never from the network itself ([canonical] is a map read): the
 * repository's metadata enrichment, the Up Next resolution, and a warm-up of the row's recent
 * series (`WatchProgressRepository.continueWatchingRow`). [version] moves on every change, so the
 * repository republishes and Home rebuilds its row.
 */
object ContinueWatchingSeriesIdentity {
    private val lock = SynchronizedObject()
    private val canonicalById = mutableMapOf<String, String>()
    private val _version = MutableStateFlow(0L)

    /** Bumped whenever [canonical] may answer differently. */
    val version: StateFlow<Long> = _version.asStateFlow()

    /**
     * Learns the IMDb id of the series [meta] describes, fetched for [requestedId]: the addon's
     * `imdb_id` when it is one, else the meta id when it is one. Both [requestedId] and the meta id
     * then group under it. An id that is already an IMDb id is never regrouped, and neither is
     * anything but a series. True when the map changed.
     */
    fun record(requestedId: String, meta: MetaDetails): Boolean {
        if (!meta.type.isSeriesLikeWatchingContentType()) return false
        val canonicalId = listOfNotNull(meta.imdbId, meta.id)
            .map(String::trim)
            .firstOrNull(String::isImdbSeriesId)
            ?: return false
        val aliases = listOf(requestedId, meta.id)
            .map(String::trim)
            .filter { id -> id.isNotEmpty() && !id.isImdbSeriesId() }
            .distinct()
        if (aliases.isEmpty()) return false
        val changed = synchronized(lock) {
            var changed = false
            aliases.forEach { alias ->
                if (canonicalById.put(alias, canonicalId) != canonicalId) changed = true
            }
            changed
        }
        if (changed) _version.update { value -> value + 1L }
        return changed
    }

    /** The id [id]'s series is grouped under: its IMDb id once learned, else [id] itself, trimmed. */
    fun canonical(id: String): String {
        val trimmed = id.trim()
        return synchronized(lock) { canonicalById[trimmed] } ?: trimmed
    }

    /** True when [id] needs no lookup: it is an IMDb id, or its IMDb id is known. */
    fun isResolved(id: String): Boolean {
        val trimmed = id.trim()
        return trimmed.isImdbSeriesId() || synchronized(lock) { trimmed in canonicalById }
    }

    /** How many ids group under another one (the diagnostics' `map=`). */
    fun aliasCount(): Int = synchronized(lock) { canonicalById.size }

    /**
     * Sign-out and profile loads; the map is learned again from metadata. Silent on purpose: both
     * callers publish right after, and a [version] bump here would have the repository publish
     * from another thread while its entries are being swapped.
     */
    fun clear() {
        synchronized(lock) { canonicalById.clear() }
    }
}

private fun String.isImdbSeriesId(): Boolean =
    length > 2 && startsWith("tt") && substring(2).all(Char::isDigit)

/** A series row for Continue Watching's grouping (the same test as `continueWatchingProgressEntries`). */
internal fun WatchProgressEntry.isContinueWatchingSeries(): Boolean =
    parentMetaType.isSeriesLikeWatchingContentType() || isEpisode

/**
 * The key Continue Watching groups [this] entry's title under: the canonical id of a series
 * ([ContinueWatchingSeriesIdentity]), the trimmed id of anything else — a `tmdb:` movie id and a
 * `tmdb:` series id of the same number are different titles.
 */
internal fun WatchProgressEntry.continueWatchingSeriesKey(canonicalSeriesId: (String) -> String): String =
    if (isContinueWatchingSeries()) canonicalSeriesId(parentMetaId) else parentMetaId.trim()

/** How many series one warm-up pass looks up at most (REMAINING_FIX #2). */
internal const val ContinueWatchingSeriesIdentityWarmUpLimit = 30

/**
 * CW alias fix (REMAINING_FIX #2): the series whose meta the row's warm-up fetches to learn their
 * IMDb id. An alias only shows as a card of its own, so the candidates are the series cards of the
 * row ([rowEntries]) stored under another id ([isResolved] false: an IMDb id needs no lookup) and
 * not looked up yet ([alreadyAttempted]) — the [limit] most recent — each with the metadata key
 * the repository's enrichment uses for it (so both share [MetaDetailsRepository]'s cache). The
 * other alias shape, an Up Next seed, is learned when its card is resolved.
 */
internal fun selectSeriesIdentityWarmUpKeys(
    rowEntries: Collection<WatchProgressEntry>,
    isResolved: (String) -> Boolean,
    alreadyAttempted: Set<String>,
    limit: Int = ContinueWatchingSeriesIdentityWarmUpLimit,
): List<WatchProgressMetadataKey> = rowEntries
    .filter(WatchProgressEntry::isContinueWatchingSeries)
    .sortedByDescending(WatchProgressEntry::lastUpdatedEpochMs)
    .distinctBy { entry -> entry.parentMetaId.trim() }
    .filter { entry ->
        val id = entry.parentMetaId.trim()
        !isMalformedNextUpSeedContentId(id) && !isResolved(id) && id !in alreadyAttempted
    }
    .take(limit.coerceAtLeast(0))
    .map(WatchProgressEntry::metadataKey)

/**
 * CW alias fix: every stored id Continue Watching shows under [card] — the card's own id
 * (trimmed) first, then, for a series, the other ids of [entries] with the same canonical id, as
 * stored. What "Remove from Continue Watching" removes, so no alias card is left behind.
 */
internal fun continueWatchingSeriesContentIds(
    entries: Collection<WatchProgressEntry>,
    card: WatchProgressEntry,
    canonicalSeriesId: (String) -> String,
): List<String> {
    val requested = card.parentMetaId.trim()
    if (requested.isEmpty()) return emptyList()
    if (!card.isContinueWatchingSeries()) return listOf(requested)
    val target = canonicalSeriesId(requested)
    val aliases = entries
        .filter(WatchProgressEntry::isContinueWatchingSeries)
        .map(WatchProgressEntry::parentMetaId)
        .filter { id -> id.trim() != requested && canonicalSeriesId(id) == target }
        .distinct()
    return listOf(requested) + aliases
}
