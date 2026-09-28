import AVKit
import Combine
import SharedCore
import SwiftUI

// Phase 3 of the hybrid player (+ post-Phase-5 polish): the native AVPlayer playback screen, chosen
// by `PlayerScreen` for Dolby-Vision-eligible files. Shows a preparing state while the on-device
// remux spins up, then a full AVPlayerViewController (native tvOS transport, scrubbing, Now Playing).
// Watch progress, resume, and Trakt live in `NativePlaybackCoordinator`; next-episode autoplay is the
// `NextEpisodeEngine` owned by `PlayerScreen` (shared with the mpv screen, so a fallback keeps its
// state). A pre-playback failure calls `onFallback` so the dispatcher can hand the same context to
// the mpv player. See docs/tvos-hybrid-player-plan.md.
//
// Unlike the mpv screen — which owns the remote and must draw its own pills — this screen integrates
// with the system player UI:
//  - Skip Intro/Outro/Recap ride `contextualActions` (the same system affordance TV+/Netflix use;
//    segments come from the shared `SkipIntroRepository`, evaluated against playback ticks).
//  - The Up Next card (`UpNextCard`, shared with the mpv screen) is app-drawn and non-focusable; its
//    interactive twins are contextual actions ("Cancel" first, then "Play Now"). OK and Menu cancel
//    and leave for the details page (OK through the host's Select observer when no card action is
//    the focused one), Down plays at once — same as mpv.
//  - End of file (`AVPlayerItemDidPlayToEndTime`): the Up Next hand-off, the end screen
//    (`PlayerEndScreen`), or — for a movie or a finale — straight back to the details page, instead
//    of resting on the last frame.
//  - Info · Subtitles · Audio live in an app-drawn swipe-down top panel (Infuse-style) presented by
//    `NativePlayerHostController` over the system player — tvOS 26 has no system swipe-down panel
//    (a `customInfoViewControllers` tab would render as an "Info" pill under the seek bar). The
//    native transport-bar Subtitles/Audio popovers stay (Enhance Dialogue etc. have no public API).
struct NativePlayerScreen: View {
    let context: PlaybackContext
    /// Up Next orchestration, owned by `PlayerScreen` (survives a native → mpv fallback).
    @ObservedObject var upNext: NextEpisodeEngine
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Info tab.
    var routingNote: String?
    /// Leave the player for the details page (the presenter closes its stream picker too).
    /// nil → just dismiss the player.
    var onExitToDetails: (() -> Void)?
    /// Open the stream picker for the next episode. nil → leave the player.
    var onPickNextSource: ((MetaVideo) -> Void)?

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: NativePlayerPanelAdapter?
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipPrompt: SkipPrompt?
    /// "Swipe down for info" hint (start + after a pause); hidden while the panel is open.
    @State private var showSwipeHint = false
    @State private var swipeHintTask: Task<Void, Never>?
    @State private var swipeHintReason: SwipeHintReason?
    @State private var panelOpen = false
    /// The end screen's cover was closed with Menu: leave for the details page once it's gone.
    @State private var endScreenClosedByMenu = false
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext,
         upNext: NextEpisodeEngine,
         onFallback: ((Double) -> Void)? = nil,
         routingNote: String? = nil,
         onExitToDetails: (() -> Void)? = nil,
         onPickNextSource: ((MetaVideo) -> Void)? = nil) {
        self.context = context
        _upNext = ObservedObject(wrappedValue: upNext)
        self.onFallback = onFallback
        self.routingNote = routingNote
        self.onExitToDetails = onExitToDetails
        self.onPickNextSource = onPickNextSource
        _coordinator = StateObject(wrappedValue: NativePlaybackCoordinator(context: context))
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.phase {
            case .preparing:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.6)
                    Text(coordinator.preparingLabel)
                        .font(Theme.Font.body)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .playing:
                if let player = coordinator.player {
                    AVPlayerContainer(
                        player: player,
                        // The card supersedes Skip Outro (its "Play Now" is the better skip).
                        skipPrompt: upNext.isCardVisible ? nil : skipPrompt,
                        upNextActions: upNextActions,
                        allowedSubtitleLanguages: coordinator.languagePlan.onlyPreferredLanguages
                            ? coordinator.languagePlan.subtitleFilterLanguages : nil,
                        panelModel: panelModel,
                        onSkip: { [weak coordinator, weak upNext] prompt in
                            // Skip Outro on credits that run to the end of the file = the next
                            // episode now (Up Next), not a seek onto the last frame.
                            if prompt.isCredits, upNext?.skipCreditsToNext(creditsEndSec: prompt.targetSec) == true {
                                return
                            }
                            coordinator?.player?.seek(to: CMTime(seconds: prompt.targetSec, preferredTimescale: 600))
                        },
                        onUpNextAction: { [weak upNext] action in
                            guard let upNext else { return }
                            Self.perform(action, on: upNext)
                        },
                        onDownPress: { [weak upNext] in upNext?.handleDown() ?? false },
                        onMenuPress: { [weak upNext] in upNext?.handleMenu() ?? false },
                        onSelectPress: { [weak upNext] in upNext?.beginSystemSelect() },
                        onSelectSettled: { [weak upNext] token in upNext?.resolveSystemSelect(token: token) },
                        onPanelOpenChanged: { [weak upNext] open in
                            panelOpen = open
                            // The Up Next countdown waits while the panel is open.
                            upNext?.setPanelOpen(open)
                        }
                    )
                    .ignoresSafeArea()
                }
            case .failed:
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                Color.clear.onAppear {
                    if let onFallback { onFallback(coordinator.lastPositionSec) } else { dismiss() }
                }
            }

            if showSwipeHint, !panelOpen, coordinator.phase == .playing, !upNext.isCardVisible {
                PlayerSwipeHint().transition(.opacity)
            }

            // Up Next card (visual only — the contextual actions above are its interactive twins).
            // Inset above the system's contextual-action pill; the extra bottom offset is
            // device-tuned for tvOS 26.
            if upNext.isCardVisible {
                UpNextCard(engine: upNext, fallbackArtwork: context.background ?? context.poster)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: showSwipeHint)
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .playing { flashSwipeHint(after: 1, reason: .start) }
        }
        .onChange(of: coordinator.isPaused) { _, paused in
            // The Up Next countdown pauses with the video.
            upNext.setPaused(paused)
            // Re-show the hint once per pause (after the pause has settled), like Infuse. Resuming
            // only cancels a PAUSE hint — the start hint must survive the initial paused→playing
            // transition, which happens right after readyToPlay.
            if paused {
                if coordinator.phase == .playing, !coordinator.isEnded { flashSwipeHint(after: 1.5, reason: .pause) }
            } else if swipeHintReason == .pause {
                hideSwipeHint()
            }
        }
        .onChange(of: coordinator.isEnded) { _, ended in
            if ended {
                hideSwipeHint()
                // Hand-off, card, end screen — or nothing to continue with: back to details.
                if upNext.playbackDidEnd(natural: coordinator.endedNaturally) == .exit { exitToDetails() }
            } else {
                // Off the last frame again (a seek back, the system player's own Play on the last
                // frame, or Play Again — which re-arms fully).
                upNext.playbackResumedFromEnd()
            }
        }
        .fullScreenCover(isPresented: endScreenPresented, onDismiss: { endScreenDidDismiss() }) {
            PlayerEndScreen(
                engine: upNext,
                title: context.title,
                artwork: context.episodeStill ?? context.background ?? context.poster,
                onNextEpisode: { upNext.playNextFromEndScreen() },
                onChooseSource: { upNext.pickSource() },
                onReplay: { replay() },
                onExit: { upNext.cancelAndExit() }
            )
        }
        .onAppear {
            let adapter = NativePlayerPanelAdapter(coordinator: coordinator, model: panelModel,
                                                   context: context, routingNote: routingNote)
            panelAdapter = adapter
            coordinator.onTick = { [weak adapter] _, _ in
                adapter?.onTick()
            }
            coordinator.onPositionTick = { [weak upNext] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
                updateSkipPrompt(position: position)
            }
            upNext.playerAttached()
            upNext.setPaused(false)
            upNext.onExitRequested = exitAction
            upNext.onPickSourceRequested = pickSourceAction
            upNext.onWillHandOff = { [weak coordinator] in coordinator?.markCompleted() }
            // The end screen's full-screen cover makes this screen disappear (→ `coordinator.stop()`
            // below) and appear again when it closes. Rebuild the pipeline only for "Play Again"
            // (`replay()` cleared the end screen first) — never on the way out: Menu closed the
            // cover, or the engine is leaving (details, a source pick, a hand-off). Restarting there
            // relaunched this same episode (and its remux) right before exiting.
            guard !endScreenClosedByMenu, upNext.endScreen == nil, !upNext.isFinished else { return }
            coordinator.start()
            if skipSegments.isEmpty { fetchSkipSegments() }
        }
        .onDisappear {
            swipeHintTask?.cancel()
            // Also when the end screen covers this screen: the pipeline is released there (progress
            // flushed as completed, Trakt closed) — "Play Again" starts a fresh session.
            coordinator.stop()
        }
    }

    private enum SwipeHintReason { case start, pause }

    private func flashSwipeHint(after delay: Double, reason: SwipeHintReason) {
        swipeHintTask?.cancel()
        swipeHintReason = reason
        swipeHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            showSwipeHint = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showSwipeHint = false
        }
    }

    private func hideSwipeHint() {
        swipeHintTask?.cancel()
        showSwipeHint = false
    }

    /// Vertical room the system contextual-action pill occupies above the bottom inset on tvOS 26,
    /// so the card sits above it rather than on top of it. Device-tuned.
    private static let contextualActionClearance: CGFloat = 96

    // MARK: - Up Next

    /// The contextual actions mirroring the card. "Cancel" comes first: when the system gives the
    /// row focus, a plain Select then cancels (the card's "OK / Menu: cancel"); "Play Now" is one
    /// step right, and Down plays at once from anywhere (`onDownPress`).
    private var upNextActions: [UpNextAction] {
        switch upNext.phase {
        case .upNext: return [.cancel, .playNow]
        case .stillWatching: return [.continueWatching, .cancel]
        case .noStream: return [.cancel, .chooseSource]
        case .hidden: return []
        }
    }

    private static func perform(_ action: UpNextAction, on engine: NextEpisodeEngine) {
        switch action {
        case .cancel: engine.cancelAndExit()
        case .playNow, .continueWatching: engine.playNow()
        case .chooseSource: engine.pickSource()
        }
    }

    private var endScreenPresented: Binding<Bool> {
        Binding(
            get: { upNext.endScreen != nil },
            set: { presented in
                // Only a user dismissal (Menu) lands here while the engine still wants the screen.
                guard !presented, upNext.endScreen != nil else { return }
                endScreenClosedByMenu = true
                upNext.endScreenDismissedByUser()
            }
        )
    }

    /// Runs once the end-screen cover is gone, so leaving for details never races its dismissal.
    private func endScreenDidDismiss() {
        guard endScreenClosedByMenu else { return }
        endScreenClosedByMenu = false
        upNext.cancelAndExit()
    }

    private func replay() {
        upNext.resetForReplay()
        coordinator.replay()
    }

    /// Leave the player for the details page (the presenter's route, else just this player).
    /// Built from values, not from this view: the engine stores it, and capturing the view — which
    /// holds the engine — would retain the engine in a cycle.
    private var exitAction: () -> Void {
        let onExitToDetails = self.onExitToDetails
        let dismiss = self.dismiss
        return {
            if let onExitToDetails {
                onExitToDetails()
            } else {
                dismiss()
            }
        }
    }

    /// Open the next episode's stream picker (the presenter's route, else leave the player).
    private var pickSourceAction: (MetaVideo) -> Void {
        let onPickNextSource = self.onPickNextSource
        let exit = exitAction
        return { video in
            if let onPickNextSource {
                onPickNextSource(video)
            } else {
                exit()
            }
        }
    }

    private func exitToDetails() {
        exitAction()
    }

    // MARK: - Skip intro/outro segments (shared repository, same rules as the mpv screen)

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Respects the Settings > Playback "Skip Intro" toggle. The outro also times the Up
    /// Next card (credits-aware trigger).
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervalsForContentId(
            // Routes kitsu:/mal: anime ids to the anime providers (same rules as the mpv screen).
            contentId: context.parentMetaId,
            season: Int32(season),
            episode: Int32(episode),
            requireSkipIntroEnabled: true
        ) { intervals, _ in
            let segments = (intervals ?? []).map { SkipSegment(start: $0.startTime, end: $0.endTime, type: $0.type) }
            print("[NativePlayer] skip segments: \(segments.count)"
                  + (segments.isEmpty ? " (none in intro DB for this episode)" : ""))
            guard !segments.isEmpty else { return }
            DispatchQueue.main.async {
                self.skipSegments = segments
                self.upNext.setSkipSegments(segments)
            }
        }
    }

    /// Offer the skip while inside a segment; the last second is excluded so the action
    /// disappears cleanly at the end (same rule as the mpv screen).
    private func updateSkipPrompt(position: Double) {
        let active = skipSegments.first { position >= $0.start && position < $0.end - PlayerChipStyle.lastSecondExclusion }
        let prompt = active.map {
            SkipPrompt(label: Self.skipLabel(for: $0.type), targetSec: $0.end,
                       isCredits: UpNextTrigger.outroTypes.contains($0.type.lowercased()))
        }
        if prompt != skipPrompt { skipPrompt = prompt }
    }

    private static func skipLabel(for type: String) -> String {
        let type = type.lowercased()
        // Every credits type Up Next knows (AniSkip "ed"/"mixed-ed", IntroDB "outro", …).
        if UpNextTrigger.outroTypes.contains(type) { return String(localized: "Skip Outro") }
        return type == "recap" ? String(localized: "Skip Recap") : String(localized: "Skip Intro")
    }
}

/// Up Next contextual actions (static titles — the countdown lives in `UpNextCard`, because a
/// per-second UIAction title change re-animates the transport bar).
enum UpNextAction: String {
    case cancel, playNow, continueWatching, chooseSource

    var title: String {
        switch self {
        case .cancel: return String(localized: "Cancel")
        case .playNow: return String(localized: "Play Now")
        case .continueWatching: return String(localized: "Continue Watching")
        case .chooseSource: return String(localized: "Choose a Source")
        }
    }

    var symbol: String {
        switch self {
        case .cancel: return "xmark"
        case .playNow: return PlayerChipStyle.nextSymbol
        case .continueWatching: return "play.fill"
        case .chooseSource: return "list.bullet"
        }
    }
}

private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipPrompt: SkipPrompt?
    let upNextActions: [UpNextAction]
    /// "Show only preferred languages" (Settings → Playback → Subtitles): restrict the panel's
    /// Subtitles list to these BCP-47 tags. nil = show every rendition.
    let allowedSubtitleLanguages: [String]?
    let panelModel: PlayerTopPanelModel
    let onSkip: (SkipPrompt) -> Void
    let onUpNextAction: (UpNextAction) -> Void
    /// Down press while the Up Next card is up → play now (returns true) instead of opening the panel.
    let onDownPress: () -> Bool
    /// Menu while the Up Next card is up → cancel and leave for details (returns true) instead of
    /// the plain exit.
    let onMenuPress: () -> Bool
    /// Select while the Up Next card may be up (OK cancels, as on mpv): a token now, settled a beat
    /// later — see `NativePlayerHostController.onSelectPress`.
    let onSelectPress: () -> Int?
    let onSelectSettled: (Int) -> Void
    let onPanelOpenChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> NativePlayerHostController {
        let host = NativePlayerHostController()
        host.playerVC.player = player
        // No `customInfoViewControllers`: on tvOS 26 that renders as an "Info" pill under the seek
        // bar. Info lives in the app-drawn swipe-down panel presented by the host instead.
        let model = panelModel
        let openChanged = onPanelOpenChanged
        host.onOpenPanel = { [weak host] in
            guard let host else { return }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model))
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            host.present(panel: panel)
            openChanged(true)
        }
        host.onPanelClosed = { openChanged(false) }
        // Set once, like `onOpenPanel`: the closures capture the stable engine weakly.
        host.onMenuPress = onMenuPress
        host.onDownPress = onDownPress
        host.onSelectPress = onSelectPress
        host.onSelectSettled = onSelectSettled
        return host
    }

    static func dismantleUIViewController(_ host: NativePlayerHostController, coordinator: Coordinator) {
        host.closePanel(animated: false)
    }

    func updateUIViewController(_ host: NativePlayerHostController, context: Context) {
        let controller = host.playerVC
        if controller.player !== player { controller.player = player }
        // Only assign on change — it's a panel-content property, not part of the transport-bar
        // signature below, and reassigning identical arrays each SwiftUI tick is pointless work.
        if context.coordinator.allowedSubtitleLanguages != allowedSubtitleLanguages {
            context.coordinator.allowedSubtitleLanguages = allowedSubtitleLanguages
            controller.allowedSubtitleOptionLanguages = allowedSubtitleLanguages
        }
        // Reinstall contextual actions only when their meaning changes — reassigning identical
        // actions every SwiftUI update makes the transport bar re-animate them. The skip target is
        // part of the signature so back-to-back segments with the same label still refresh the
        // captured seek position.
        let upNextSignature = upNextActions.map(\.rawValue).joined(separator: ",")
        let skipSignature = skipPrompt.map { "\($0.label)@\($0.targetSec)\($0.isCredits ? "c" : "")" } ?? "-"
        let signature = "\(skipSignature)|\(upNextSignature.isEmpty ? "-" : upNextSignature)"
        guard signature != context.coordinator.actionsSignature else { return }
        context.coordinator.actionsSignature = signature

        var actions: [UIAction] = []
        if let prompt = skipPrompt {
            let skip = onSkip
            actions.append(UIAction(title: prompt.label,
                                    image: UIImage(systemName: PlayerChipStyle.skipSymbol)) { _ in skip(prompt) })
        }
        let perform = onUpNextAction
        for upNextAction in upNextActions {
            actions.append(UIAction(title: upNextAction.title,
                                    image: UIImage(systemName: upNextAction.symbol)) { _ in perform(upNextAction) })
        }
        controller.contextualActions = actions
    }

    final class Coordinator {
        var actionsSignature = ""
        var allowedSubtitleLanguages: [String]?
    }
}
