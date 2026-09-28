package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watched.WatchedItem
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * CW alias fix (REMAINING_FIX #2): one show stored under a TMDB and an IMDb id is one series for
 * the Continue Watching row, and only for its display.
 */
class ContinueWatchingSeriesIdentityTest {
    private val tmdbId = "tmdb:1396"
    private val imdbId = "tt0903747"

    /** The mapping the row learns for Breaking Bad; everything else is its own series. */
    private val breakingBad: (String) -> String = { id ->
        when (id.trim()) {
            tmdbId -> imdbId
            else -> id.trim()
        }
    }
    private val unmapped: (String) -> String = { id -> id.trim() }

    @AfterTest
    fun clearIdentity() {
        ContinueWatchingSeriesIdentity.clear()
    }

    private fun episode(
        showId: String,
        episode: Int,
        updatedAt: Long,
        completed: Boolean = false,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:$episode",
        title = "Breaking Bad",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = if (completed) 2_700_000L else 600_000L,
        durationMs = 2_800_000L,
        lastUpdatedEpochMs = updatedAt,
        isCompleted = completed,
    )

    private fun movie(id: String, updatedAt: Long): WatchProgressEntry = WatchProgressEntry(
        contentType = "movie",
        parentMetaId = id,
        parentMetaType = "movie",
        videoId = id,
        title = id,
        lastPositionMs = 600_000L,
        durationMs = 6_000_000L,
        lastUpdatedEpochMs = updatedAt,
    )

    private fun row(entries: List<WatchProgressEntry>, canonical: (String) -> String) =
        buildContinueWatchingRowEntries(
            entries = entries,
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            canonicalSeriesId = canonical,
        )

    private fun seeds(
        entries: List<WatchProgressEntry>,
        canonical: (String) -> String,
        watchedItems: List<WatchedItem> = emptyList(),
    ) = buildContinueWatchingNextUpSeeds(
        progressEntries = entries,
        watchedItems = watchedItems,
        inProgressEntries = row(entries, canonical),
        preferFurthestEpisode = true,
        dismissedNextUpKeys = emptySet(),
        recencyCutoffEpochMs = null,
        limit = 20,
        canonicalSeriesId = canonical,
    )

    // The row

    @Test
    fun `a show under a TMDB and an IMDb id is one card, the newest row of both`() {
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chain = episode(imdbId, episode = 5, updatedAt = 5_000L)

        val result = row(listOf(legacy, chain), breakingBad)

        assertEquals(listOf("$imdbId:1:5"), result.map { it.videoId })
    }

    @Test
    fun `the newest row wins whichever id it was stored under`() {
        val chain = episode(imdbId, episode = 5, updatedAt = 5_000L)
        val resumedFromTheOldCard = episode(tmdbId, episode = 6, updatedAt = 6_000L)

        val result = row(listOf(chain, resumedFromTheOldCard), breakingBad)

        // The card keeps its own stored id: it launches under the id its progress was written with.
        assertEquals(listOf("$tmdbId:1:6"), result.map { it.videoId })
        assertEquals(tmdbId, result.single().parentMetaId)
    }

    @Test
    fun `a finished chain leaves no card and one Up Next seed`() {
        // The legacy card, then a chain under the IMDb id that ended on the Up Next card.
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val entries = listOf(legacy, chainEnd)

        assertTrue(row(entries, breakingBad).isEmpty())
        val result = seeds(entries, breakingBad)
        assertEquals(1, result.size)
        assertEquals(imdbId, result.single().contentId)
        assertEquals(5, result.single().episodeNumber)
    }

    @Test
    fun `a finished episode under each id is still one seed, the most recent`() {
        val legacyDone = episode(tmdbId, episode = 2, updatedAt = 2_000L, completed = true)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)

        val result = seeds(listOf(legacyDone, chainEnd), breakingBad)

        assertEquals(listOf(imdbId to 5), result.map { it.contentId to it.episodeNumber })
    }

    @Test
    fun `an in-progress card under one id suppresses the seed of the other`() {
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val resumed = episode(tmdbId, episode = 6, updatedAt = 6_000L)

        assertTrue(seeds(listOf(chainEnd, resumed), breakingBad).isEmpty())
    }

    @Test
    fun `unmapped ids stay separate series as before`() {
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val entries = listOf(legacy, chainEnd)

        assertEquals(listOf("$tmdbId:1:1"), row(entries, unmapped).map { it.videoId })
        // The legacy card's in-progress row does not suppress the other id's seed.
        assertEquals(listOf(imdbId), seeds(entries, unmapped).map { it.contentId })
        // The row's default grouping is the learned one, and nothing is learned yet.
        assertEquals(
            row(entries, unmapped),
            buildContinueWatchingRowEntries(entries = entries, isDroppedShow = { false }, recencyCutoffEpochMs = null),
        )
    }

    @Test
    fun `the merged row keeps one card per series next to Up Next cards`() {
        val inProgress = episode(tmdbId, episode = 6, updatedAt = 6_000L)
        val upNextOfTheOtherId = episode(imdbId, episode = 6, updatedAt = 5_000L).copy(
            lastPositionMs = 0L,
            source = WatchProgressSourceNextUp,
        )
        val otherShowUpNext = episode("tt0944947", episode = 2, updatedAt = 4_000L).copy(
            lastPositionMs = 0L,
            source = WatchProgressSourceNextUp,
        )

        val merged = mergeContinueWatchingNextUp(
            inProgressEntries = listOf(inProgress),
            nextUpEntries = listOf(upNextOfTheOtherId, otherShowUpNext),
            canonicalSeriesId = breakingBad,
        )
        val unmerged = mergeContinueWatchingNextUp(
            inProgressEntries = listOf(inProgress),
            nextUpEntries = listOf(upNextOfTheOtherId, otherShowUpNext),
            canonicalSeriesId = unmapped,
        )

        assertEquals(listOf("$tmdbId:1:6", "tt0944947:1:2"), merged.map { it.videoId })
        assertEquals(3, unmerged.size)
    }

    @Test
    fun `a movie is never grouped with a series of the same id`() {
        // tmdb movie 1396 and tmdb series 1396 are different titles.
        val movieCard = movie(tmdbId, updatedAt = 6_000L)
        val seriesCard = episode(imdbId, episode = 2, updatedAt = 5_000L)

        val result = row(listOf(movieCard, seriesCard), breakingBad)
        val merged = mergeContinueWatchingNextUp(
            inProgressEntries = result,
            nextUpEntries = listOf(episode("tt0944947", 1, 1_000L).copy(source = WatchProgressSourceNextUp)),
            canonicalSeriesId = breakingBad,
        )

        assertEquals(listOf(tmdbId, imdbId), result.map { it.parentMetaId })
        assertEquals(listOf(tmdbId, imdbId, "tt0944947"), merged.map { it.parentMetaId })
    }

    // Removal

    @Test
    fun `removing a series card removes every id of the series`() {
        val entries = listOf(
            episode(tmdbId, episode = 1, updatedAt = 1_000L),
            episode(tmdbId, episode = 2, updatedAt = 2_000L),
            episode(imdbId, episode = 5, updatedAt = 5_000L),
            episode("tt0944947", episode = 3, updatedAt = 3_000L),
        )

        assertEquals(
            listOf(imdbId, tmdbId),
            continueWatchingSeriesContentIds(entries, card = entries[2], canonicalSeriesId = breakingBad),
        )
        assertEquals(
            listOf(tmdbId, imdbId),
            continueWatchingSeriesContentIds(entries, card = entries[0], canonicalSeriesId = breakingBad),
        )
        assertEquals(
            listOf(imdbId),
            continueWatchingSeriesContentIds(entries, card = entries[2], canonicalSeriesId = unmapped),
        )
    }

    @Test
    fun `removing a movie card never takes a series`() {
        val movieCard = movie(tmdbId, updatedAt = 6_000L)
        val entries = listOf(movieCard, episode(imdbId, episode = 2, updatedAt = 5_000L))

        assertEquals(listOf(tmdbId), continueWatchingSeriesContentIds(entries, movieCard, breakingBad))
    }

    // The identity map

    private fun seriesMeta(id: String, imdbId: String?, type: String = "series") = MetaDetails(
        id = id,
        type = type,
        name = "Breaking Bad",
        imdbId = imdbId,
        videos = listOf(MetaVideo(id = "$id:1:1", title = "Pilot", season = 1, episode = 1)),
    )

    @Test
    fun `a series meta maps the requested and the meta id to its IMDb id`() {
        assertTrue(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = "tmdb:tv:1396", imdbId = imdbId)))

        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(" $tmdbId "))
        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical("tmdb:tv:1396"))
        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(imdbId))
        assertTrue(ContinueWatchingSeriesIdentity.isResolved(tmdbId))
        assertEquals(2, ContinueWatchingSeriesIdentity.aliasCount())
        // Learning it again changes nothing.
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = "tmdb:tv:1396", imdbId = imdbId)))
    }

    @Test
    fun `the meta id counts when the addon names no IMDb id`() {
        // An addon that answers a tmdb request with its IMDb-keyed meta.
        assertTrue(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = imdbId, imdbId = null)))

        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
    }

    @Test
    fun `nothing is learned without an IMDb id, for a movie, or for an IMDb id`() {
        val versionBefore = ContinueWatchingSeriesIdentity.version.value

        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = null)))
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = "tt", type = "series")))
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId, type = "movie")))
        // An IMDb id is canonical already: it is never regrouped under another one.
        assertFalse(ContinueWatchingSeriesIdentity.record("tt0000001", seriesMeta(id = "tt0000001", imdbId = imdbId)))

        assertEquals(tmdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
        assertEquals("tt0000001", ContinueWatchingSeriesIdentity.canonical("tt0000001"))
        assertFalse(ContinueWatchingSeriesIdentity.isResolved(tmdbId))
        assertEquals(versionBefore, ContinueWatchingSeriesIdentity.version.value)
    }

    @Test
    fun `a learned id moves the version and clear forgets it`() {
        val versionBefore = ContinueWatchingSeriesIdentity.version.value

        ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId))
        assertTrue(ContinueWatchingSeriesIdentity.version.value > versionBefore)

        ContinueWatchingSeriesIdentity.clear()
        assertEquals(tmdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
        assertEquals(0, ContinueWatchingSeriesIdentity.aliasCount())
    }

    @Test
    fun `the row groups with what the map learned`() {
        ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId))
        val entries = listOf(episode(tmdbId, 1, 1_000L), episode(imdbId, 5, 5_000L))

        val result = buildContinueWatchingRowEntries(entries = entries, isDroppedShow = { false }, recencyCutoffEpochMs = null)
        val legacyRow = entries.continueWatchingEntries()

        assertEquals(listOf("$imdbId:1:5"), result.map { it.videoId })
        // Only the row groups by the learned id: the legacy list, enrichment and mobile do not.
        assertEquals(2, legacyRow.size)
    }

    // The warm-up

    @Test
    fun `the warm-up looks up the recent series stored under another id, once`() {
        val entries = listOf(
            episode(tmdbId, episode = 1, updatedAt = 9_000L),
            episode(tmdbId, episode = 2, updatedAt = 8_000L),
            episode(imdbId, episode = 5, updatedAt = 7_000L),
            episode("kitsu:1", episode = 1, updatedAt = 6_000L),
            episode("tmdb:", episode = 1, updatedAt = 5_000L),
            movie("tmdb:550", updatedAt = 4_000L),
            episode("tmdb:42", episode = 1, updatedAt = 3_000L),
            episode("tmdb:43", episode = 1, updatedAt = 2_000L),
        )

        val keys = selectSeriesIdentityWarmUpKeys(
            entries = entries,
            isResolved = { id -> id.startsWith("tt") || id == "tmdb:42" },
            alreadyAttempted = setOf("kitsu:1"),
            seriesLimit = 5,
        )

        // The IMDb id, the resolved one, the attempted one and the malformed id are left out, and
        // the movie is no series; tmdb:43 is past the 5 most recent series.
        assertEquals(listOf(WatchProgressMetadataKey(metaId = tmdbId, metaType = "series")), keys)
    }
}
