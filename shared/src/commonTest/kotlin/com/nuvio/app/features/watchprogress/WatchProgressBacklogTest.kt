package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** CW sync #2: which rows the one-time post-pull backlog push sends. */
class WatchProgressBacklogTest {
    @Test
    fun `sends only the still-dirty rows, newest first`() {
        val e1 = episode(episode = 1, updatedAt = 1_000L)
        val e2 = episode(episode = 2, updatedAt = 3_000L)
        val e3 = episode(episode = 3, updatedAt = 2_000L)
        val acknowledged = episode(episode = 4, updatedAt = 9_000L)

        val backlog = selectDirtyWatchProgressBacklog(
            entries = listOf(e1, e2, e3, acknowledged),
            dirtyProgressKeys = setOf(e1.resolvedProgressKey(), e2.resolvedProgressKey(), e3.resolvedProgressKey()),
        )

        assertEquals(listOf(2, 3, 1), backlog.map { it.episodeNumber })
    }

    @Test
    fun `is capped to the newest rows`() {
        val entries = (1..250).map { number -> episode(episode = number, updatedAt = number * 1_000L) }

        val backlog = selectDirtyWatchProgressBacklog(
            entries = entries,
            dirtyProgressKeys = entries.mapTo(mutableSetOf()) { it.resolvedProgressKey() },
        )

        assertEquals(WATCH_PROGRESS_BACKLOG_PUSH_LIMIT, backlog.size)
        assertEquals(250, backlog.first().episodeNumber)
        assertEquals(51, backlog.last().episodeNumber)
    }

    @Test
    fun `leaves out rows the server could not store`() {
        val noVideo = episode(episode = 1, updatedAt = 1_000L).copy(videoId = " ")
        val noContent = episode(episode = 2, updatedAt = 2_000L).copy(parentMetaId = "", progressKey = "orphan")
        val fine = episode(episode = 3, updatedAt = 3_000L)

        val backlog = selectDirtyWatchProgressBacklog(
            entries = listOf(noVideo, noContent, fine),
            dirtyProgressKeys = setOf(noVideo.resolvedProgressKey(), "orphan", fine.resolvedProgressKey()),
        )

        assertEquals(listOf(fine.resolvedProgressKey()), backlog.map { it.resolvedProgressKey() })
    }

    @Test
    fun `nothing dirty sends nothing`() {
        assertTrue(
            selectDirtyWatchProgressBacklog(
                entries = listOf(episode(episode = 1, updatedAt = 1_000L)),
                dirtyProgressKeys = emptySet(),
            ).isEmpty(),
        )
    }

    private fun episode(episode: Int, updatedAt: Long) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = "tt0944947",
        parentMetaType = "series",
        videoId = "tt0944947:1:$episode",
        title = "Game of Thrones",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = 60_000L,
        durationMs = 3_600_000L,
        lastUpdatedEpochMs = updatedAt,
    )
}
