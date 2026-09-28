package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.profiles.ProfileRepository
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * CW legacy diagnosis (REMAINING_FIX #4): a playback write for the active profile while another
 * profile is loaded here used to reach the disk only, where Home never looks.
 */
class PlaybackWriteProfilePathTest {
    @Test
    fun `the loaded active profile writes in memory`() {
        assertEquals(PlaybackWriteProfilePath.LOADED, playbackWriteProfilePath(targetProfileId = 1, loadedProfileId = 1, activeProfileId = 1))
    }

    @Test
    fun `the active profile loaded nowhere is loaded first`() {
        assertEquals(
            PlaybackWriteProfilePath.RELOAD_ACTIVE,
            playbackWriteProfilePath(targetProfileId = 2, loadedProfileId = 1, activeProfileId = 2),
        )
    }

    @Test
    fun `a profile that is not the active one only goes to disk`() {
        assertEquals(
            PlaybackWriteProfilePath.OTHER_PROFILE,
            playbackWriteProfilePath(targetProfileId = 2, loadedProfileId = 2, activeProfileId = 1),
        )
        assertEquals(
            PlaybackWriteProfilePath.OTHER_PROFILE,
            playbackWriteProfilePath(targetProfileId = 3, loadedProfileId = 1, activeProfileId = 2),
        )
    }

    @Test
    fun `a write for the active profile loaded nowhere reaches the published state`() {
        val activeProfileId = ProfileRepository.activeProfileId
        val otherProfileId = activeProfileId + 6
        val showId = "tt0000042"
        try {
            WatchProgressRepository.ensureLoaded()
            // The repository is left on another profile than the active one.
            WatchProgressRepository.onProfileChanged(otherProfileId)

            WatchProgressRepository.upsertPlaybackProgress(
                session = WatchProgressPlaybackSession(
                    profileId = activeProfileId,
                    contentType = "series",
                    parentMetaId = showId,
                    parentMetaType = "series",
                    videoId = "$showId:1:2",
                    title = "Profile Test Show",
                    poster = "poster.jpg",
                    background = "backdrop.jpg",
                    seasonNumber = 1,
                    episodeNumber = 2,
                ),
                snapshot = PlayerPlaybackSnapshot(
                    isLoading = false,
                    isPlaying = true,
                    durationMs = 2_800_000L,
                    positionMs = 600_000L,
                ),
                syncRemote = false,
            )

            assertTrue(WatchProgressRepository.uiState.value.entries.any { it.parentMetaId == showId })
            assertTrue(
                WatchProgressRepository.continueWatchingRow().any { it.parentMetaId == showId },
                "the Home row reads the published state",
            )
            val header = WatchProgressRepository.continueWatchingDiagnosticLines().take(2)
            assertTrue(header.first().startsWith("cur=$activeProfileId act=$activeProfileId "), header.toString())
            assertTrue(" xprof=1 " in header.first(), header.toString())
            assertEquals(
                "xprof last reload target=$activeProfileId current=$otherProfileId active=$activeProfileId",
                header[1],
            )
        } finally {
            WatchProgressRepository.clearLocalState()
        }
    }
}
