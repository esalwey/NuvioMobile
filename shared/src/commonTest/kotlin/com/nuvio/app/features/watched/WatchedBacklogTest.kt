package com.nuvio.app.features.watched

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** CW sync #2: which watched marks the one-time post-pull backlog push sends. */
class WatchedBacklogTest {
    @Test
    fun `sends only the still-dirty marks, most recent first`() {
        val items = listOf(
            mark(episode = 1, markedAt = 1_000L),
            mark(episode = 2, markedAt = 3_000L),
            mark(episode = 3, markedAt = 2_000L),
            mark(episode = 4, markedAt = 9_000L),
        ).associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
        val dirty = items.filterValues { it.episode != 4 }.keys + watchedItemKey("series", "tt0944947", 1, 99)

        val backlog = selectDirtyWatchedBacklog(items = items, dirtyKeys = dirty)

        assertEquals(listOf(2, 3, 1), backlog.map { it.episode })
    }

    @Test
    fun `is capped to the most recent marks`() {
        val items = (1..250)
            .map { number -> mark(episode = number, markedAt = 1_700_000_000_000L + number) }
            .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }

        val backlog = selectDirtyWatchedBacklog(items = items, dirtyKeys = items.keys)

        assertEquals(WATCHED_BACKLOG_PUSH_LIMIT, backlog.size)
        assertEquals(250, backlog.first().episode)
        assertEquals(51, backlog.last().episode)
    }

    @Test
    fun `nothing dirty sends nothing`() {
        val item = mark(episode = 1, markedAt = 1_000L)
        assertTrue(
            selectDirtyWatchedBacklog(
                items = mapOf(watchedItemKey(item.type, item.id, item.season, item.episode) to item),
                dirtyKeys = emptySet(),
            ).isEmpty(),
        )
    }

    private fun mark(episode: Int, markedAt: Long) = WatchedItem(
        id = "tt0944947",
        type = "series",
        name = "Game of Thrones",
        season = 1,
        episode = episode,
        markedAtEpochMs = markedAt,
    )
}
