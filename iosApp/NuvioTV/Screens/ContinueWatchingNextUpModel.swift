import Foundation
import SharedCore

/// CW-2: the Up Next cards of Home's Continue Watching row — the rules live in the shared
/// `ContinueWatchingNextUp.kt` (mobile HomeScreen's next-up pipeline). A series whose latest watched
/// episode is finished used to vanish from the row after every binge; its next released episode now
/// comes back as an Up Next card, resolved from the series metadata (cache-first), until the viewer
/// dismisses it or plays on (an in-progress card then takes its place).
///
/// Owned by `HomeViewModel`, which rebuilds the row through `row(inProgress:)` whenever its own
/// inputs change and whenever this model reports one (`onChange`: a card resolved, or the watched
/// items / Continue Watching preferences moved).
@MainActor
final class ContinueWatchingNextUpModel {
    /// A resolution landed or an input changed: the owner rebuilds its row.
    var onChange: (() -> Void)?

    /// Seeds considered per row build (mobile resolves up to 32; the row's legacy cap is 20).
    private static let seedLimit: Int32 = 20
    private static let maxConcurrentResolutions = 4
    /// A resolution that could not fetch the series meta (offline, add-on down) waits this long.
    private static let retryDelay: TimeInterval = 120

    private enum Resolution {
        case card(WatchProgressEntry)
        case nothing
        case failed(retryAt: Date)
    }

    /// Keyed by seed (series · finished episode) + day + the furthest-episode preference.
    private var resolutions: [String: Resolution] = [:]
    private var inFlight: Set<String> = []
    /// Up Next card videoId → the dismiss key its "Remove" writes.
    private var dismissKeyByVideoId: [String: String] = [:]
    /// Bumped by `reset()`: a resolution started for the previous profile never lands.
    private var generation = 0
    private var watchedWatcher: FlowWatcher?
    private var prefsWatcher: FlowWatcher?
    private var watchedItems: [WatchedItem] = []
    private var prefs: ContinueWatchingPreferencesUiState?

    func start() {
        guard watchedWatcher == nil else { return }
        WatchedRepository.shared.ensureLoaded()
        ContinueWatchingPreferencesRepository.shared.ensureLoaded()
        watchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? WatchedUiState else { return }
            self.watchedItems = state.items
            self.onChange?()
        }
        prefsWatcher = FlowWatcherKt.watch(ContinueWatchingPreferencesRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? ContinueWatchingPreferencesUiState else { return }
            self.prefs = state
            self.onChange?()
        }
    }

    func stop() {
        watchedWatcher?.cancel()
        watchedWatcher = nil
        prefsWatcher?.cancel()
        prefsWatcher = nil
    }

    /// Profile switch / sign-out: everything here is profile-scoped.
    func reset() {
        stop()
        generation += 1
        resolutions = [:]
        inFlight = []
        dismissKeyByVideoId = [:]
        watchedItems = []
        prefs = nil
    }

    /// An Up Next card rather than recorded progress.
    static func isNextUp(_ entry: WatchProgressEntry) -> Bool {
        entry.source == ContinueWatchingNextUpKt.WatchProgressSourceNextUp
    }

    /// The row: the in-progress entries plus the resolved Up Next cards, most recent first, one card
    /// per title. Seeds not resolved yet are resolved in the background (`onChange` follows).
    func row(inProgress: [WatchProgressEntry]) -> [WatchProgressEntry] {
        let preferFurthest = prefs?.upNextFromFurthestEpisode ?? true
        let seeds = currentSeeds(inProgress: inProgress, limit: Self.seedLimit)
        let today = CurrentDateProvider.shared.todayIsoDate()
        var cards: [WatchProgressEntry] = []
        var dismissKeys: [String: String] = [:]
        var liveKeys: Set<String> = []
        for seed in seeds {
            let key = "\(seed.dismissKey)|\(today)|\(preferFurthest)"
            liveKeys.insert(key)
            switch resolutions[key] {
            case .card(let entry)?:
                cards.append(entry)
                dismissKeys[entry.videoId] = seed.dismissKey
            case .nothing?:
                break
            case .failed(let retryAt)?:
                if retryAt <= Date() {
                    resolve(seed, key: key, today: today, preferFurthest: preferFurthest)
                }
            case nil:
                resolve(seed, key: key, today: today, preferFurthest: preferFurthest)
            }
        }
        // Seeds that left (played on, dismissed, a newer episode finished) drop their resolution.
        resolutions = resolutions.filter { liveKeys.contains($0.key) }
        dismissKeyByVideoId = dismissKeys
        return ContinueWatchingNextUpKt.mergeContinueWatchingNextUp(
            inProgressEntries: inProgress,
            nextUpEntries: cards
        )
    }

    /// "Remove from Continue Watching" on an Up Next card (mobile): dismissed until another episode
    /// of the series is finished — the shared progress write clears a series' dismiss keys.
    func dismiss(_ entry: WatchProgressEntry) {
        guard let key = dismissKeyByVideoId[entry.videoId] else { return }
        ContinueWatchingPreferencesRepository.shared.addDismissedNextUpKey(key: key)
    }

    /// CW-3: once a series' progress is removed, its episode marks would put an Up Next card back at
    /// once — dismiss that one too, so "Remove" takes the show off the row until it is played again.
    func dismissReplacement(forContentId contentId: String, inProgress: [WatchProgressEntry]) {
        for seed in currentSeeds(inProgress: inProgress, limit: Int32.max) where seed.contentId == contentId {
            ContinueWatchingPreferencesRepository.shared.addDismissedNextUpKey(key: seed.dismissKey)
        }
    }

    private func currentSeeds(inProgress: [WatchProgressEntry], limit: Int32) -> [ContinueWatchingNextUpSeed] {
        let dismissed: Set<String> = prefs?.dismissedNextUpKeys ?? []
        return ContinueWatchingNextUp.shared.seeds(
            watchedItems: watchedItems,
            inProgressEntries: inProgress,
            preferFurthestEpisode: prefs?.upNextFromFurthestEpisode ?? true,
            dismissedNextUpKeys: dismissed,
            limit: limit
        )
    }

    private func resolve(_ seed: ContinueWatchingNextUpSeed, key: String, today: String, preferFurthest: Bool) {
        guard !inFlight.contains(key), inFlight.count < Self.maxConcurrentResolutions else { return }
        inFlight.insert(key)
        let generation = self.generation
        ContinueWatchingNextUp.shared.resolveCard(
            seed: seed,
            watchedItems: watchedItems,
            todayIsoDate: today,
            preferFurthestEpisode: preferFurthest
        ) { [weak self] resolution, _ in
            // Suspend completions can land off-main; hop before touching model state.
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.inFlight.remove(key)
                if let resolution, resolution.isConclusive {
                    if let entry = resolution.entry {
                        self.resolutions[key] = .card(entry)
                    } else {
                        self.resolutions[key] = .nothing
                    }
                } else {
                    self.resolutions[key] = .failed(retryAt: Date().addingTimeInterval(Self.retryDelay))
                }
                // Also what starts the seeds the concurrency cap held back.
                self.onChange?()
            }
        }
    }
}
