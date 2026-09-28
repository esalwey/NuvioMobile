import SharedCore
import SwiftUI

/// End-of-playback screen shared by both engines (AES-2 / NEXT-2 / PLY-3), presented when the file
/// ended with a next episode but no pending hand-off (autoplay off, the card dismissed by a seek
/// back, or no stream found). Movies and series finales never get here — they return to details.
///
/// Default focus is the way forward, never "Play Again": "Next Episode", or "Choose a Source" when
/// no stream could be auto-selected for the next episode. "Play Again" is last in the row so a
/// reflexive Select can't restart the episode.
///
/// Look: the series backdrop under the Details page's scrims (`ArtworkBackdrop`; the episode still,
/// blurred, when there's none), what just ended named like the player chrome (series, then
/// "S1 · E4 · Name"), the next episode with its still and synopsis, and the Details action-row
/// grammar — one accent-tinted `.glassProminent` primary, `.glass` for the rest, in a
/// `GlassEffectContainer`.
struct PlayerEndScreen: View {
    @ObservedObject var engine: NextEpisodeEngine
    /// The episode that just ended.
    let title: String
    /// Background art (episode still, series backdrop or poster).
    let artwork: String?
    let onNextEpisode: () -> Void
    let onChooseSource: () -> Void
    let onReplay: () -> Void
    let onExit: () -> Void

    /// The series record from the shared meta cache — its name heads the screen, its backdrop sits
    /// behind it. nil on a cold cache: the launch title and `artwork` stand in. Read at init so the
    /// first frame already has it (no still-to-backdrop swap under the cover's transition).
    private let seriesArt: CachedTitleArt?

    init(engine: NextEpisodeEngine,
         title: String,
         artwork: String?,
         onNextEpisode: @escaping () -> Void,
         onChooseSource: @escaping () -> Void,
         onReplay: @escaping () -> Void,
         onExit: @escaping () -> Void) {
        _engine = ObservedObject(wrappedValue: engine)
        self.title = title
        self.artwork = artwork
        self.onNextEpisode = onNextEpisode
        self.onChooseSource = onChooseSource
        self.onReplay = onReplay
        self.onExit = onExit
        seriesArt = CachedTitleArt.peek(type: engine.contentType, id: engine.parentMetaId)
    }

    /// Focus targets (internal, not private: it types the `@FocusState` below).
    enum Target: Hashable {
        case primary, back, replay
    }

    @FocusState private var focus: Target?

    private static let stillSize = CGSize(width: 384, height: 216)

    private var choosesSource: Bool { engine.endScreen == .chooseSource }

    /// What just ended: series · code · episode name.
    private var finished: PlaybackTitleParts {
        PlaybackTitleParts(launchTitle: title, season: engine.currentSeason, episode: engine.currentEpisode,
                           seriesName: seriesArt?.name, episodes: engine.episodes)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // A real backdrop stays sharp; the low-resolution still stand-in is blurred.
            ArtworkBackdrop(url: seriesArt?.background ?? artwork,
                            blurRadius: seriesArt?.background == nil ? 30 : 0)

            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if let next = engine.nextVideo {
                    nextEpisode(next)
                }
                buttons
            }
            .padding(Theme.Spacing.screen)
        }
        .defaultFocus($focus, .primary)
        .onAppear { focusPrimary() }
        // "Next Episode" turns into "Choose a Source" when the search fails: keep focus on the
        // way forward instead of letting it fall onto "Play Again".
        .onChange(of: engine.endScreen) { _, _ in focusPrimary() }
        // Menu = "Back to Details", handled here so the cover never closes onto the player first
        // (which would bring it back — pipeline, display mode — only to leave it again). The
        // presenters still handle a system dismissal of the cover the same way, as a fallback.
        .onExitCommand { onExit() }
    }

    private func focusPrimary() {
        DispatchQueue.main.async { focus = .primary }
    }

    // MARK: - What just ended

    private var header: some View {
        let parts = finished
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("That's the end of")
                .font(Theme.Font.sectionTitle.weight(.regular))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(parts.heading)
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            if let detail = parts.detail {
                Text(detail)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 1200, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Next episode

    private func nextEpisode(_ next: MetaVideo) -> some View {
        let still: String? = next.thumbnail
        let image = CachedTitleArt.nonEmpty(still) ?? seriesArt?.background ?? artwork
        let overview: String? = CachedTitleArt.nonEmpty(next.overview)
        return HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            CachedAsyncImage(string: image)
                .frame(width: Self.stillSize.width, height: Self.stillSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(nextEyebrow(next))
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(CachedTitleArt.nonEmpty(next.title) ?? engine.nextEpisodeTitle)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let overview {
                    Text(overview)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3)
                        .padding(.top, Theme.Spacing.xxs)
                }
                statusLine
                    .padding(.top, Theme.Spacing.xxs)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Next Episode · S1 · E5", the Up Next card's eyebrow.
    private func nextEyebrow(_ next: MetaVideo) -> String {
        let label = String(localized: "Next Episode")
        guard let season = next.season?.value, let episode = next.episode?.value else { return label }
        return "\(label) \u{00B7} \(PlaybackTitleParts.episodeCode(season: season, episode: episode))"
    }

    @ViewBuilder
    private var statusLine: some View {
        if choosesSource {
            Label("No stream found for the next episode.", systemImage: "exclamationmark.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if engine.playWhenReady && engine.isSearching {
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().scaleEffect(0.6)
                Text("Finding a source\u{2026}")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Actions

    private var buttons: some View {
        GlassEffectContainer(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                primaryButton
                Button(action: onExit) {
                    actionLabel("Back to Details", systemImage: "chevron.backward")
                }
                .buttonStyle(.glass)
                .focused($focus, equals: .back)
                Button(action: onReplay) {
                    actionLabel("Play Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .focused($focus, equals: .replay)
            }
        }
        .focusSection()
    }

    /// The way forward, prominent like Details' Play (accent-tinted glass; `prominentAccentLabel`
    /// keeps its label legible on the White theme's near-white fill, BUG-14).
    @ViewBuilder
    private var primaryButton: some View {
        if choosesSource {
            Button(action: onChooseSource) {
                actionLabel("Choose a Source", systemImage: "list.bullet")
                    .prominentAccentLabel()
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.Palette.accent)
            .focused($focus, equals: .primary)
        } else {
            Button(action: onNextEpisode) {
                actionLabel("Next Episode", systemImage: PlayerChipStyle.nextSymbol)
                    .prominentAccentLabel()
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.Palette.accent)
            .focused($focus, equals: .primary)
        }
    }

    /// Details' action-row label metrics (meta type, roomy horizontal padding).
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
    }
}
