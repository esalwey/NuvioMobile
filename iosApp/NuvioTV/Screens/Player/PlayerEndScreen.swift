import SharedCore
import SwiftUI

/// End-of-playback screen shared by both engines (AES-2 / NEXT-2 / PLY-3), presented when the file
/// ended with a next episode but no pending hand-off (autoplay off, the card dismissed by a seek
/// back, or no stream found). Movies and series finales never get here — they return to details.
///
/// Default focus is the way forward, never "Play Again": "Next Episode", or "Choose a Source" when
/// no stream could be auto-selected for the next episode. "Play Again" is last in the row so a
/// reflexive Select can't restart the episode.
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

    /// Focus targets (internal, not private: it types the `@FocusState` below, and the memberwise
    /// initializer must stay internal for the player screens).
    enum Target: Hashable {
        case primary, back, replay
    }

    @FocusState private var focus: Target?

    private static let stillSize = CGSize(width: 384, height: 216)

    private var choosesSource: Bool { engine.endScreen == .chooseSource }

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.Palette.background.ignoresSafeArea()
            if let artwork, !artwork.isEmpty {
                CachedAsyncImage(string: artwork)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 30)
                    .opacity(0.45)
                    .ignoresSafeArea()
            }
            LinearGradient(
                colors: [Theme.Palette.background.opacity(0.92), Theme.Palette.background.opacity(0.35)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("That's the end of")
                        .font(Theme.Font.screenTitle.weight(.regular))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(title)
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: 1200, alignment: .leading)
                }
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

    // MARK: - Next episode

    private func nextEpisode(_ next: MetaVideo) -> some View {
        let still: String? = next.thumbnail
        let image = (still ?? "").isEmpty ? artwork : still
        return HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            CachedAsyncImage(string: image)
                .frame(width: Self.stillSize.width, height: Self.stillSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Next Episode")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let season = next.season?.value, let episode = next.episode?.value {
                    // "SxEy", the app's episode code (not localized, like the episode chips).
                    Text(verbatim: "S\(season)E\(episode)")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Text(next.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                statusLine
                    .padding(.top, Theme.Spacing.xxs)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
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
        HStack(spacing: Theme.Spacing.md) {
            if choosesSource {
                Button(action: onChooseSource) {
                    Label("Choose a Source", systemImage: "list.bullet")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .focused($focus, equals: .primary)
            } else {
                Button(action: onNextEpisode) {
                    Label("Next Episode", systemImage: PlayerChipStyle.nextSymbol)
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .focused($focus, equals: .primary)
            }
            Button(action: onExit) {
                Label("Back to Details", systemImage: "chevron.backward")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .focused($focus, equals: .back)
            Button(action: onReplay) {
                Label("Play Again", systemImage: "arrow.counterclockwise")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .focused($focus, equals: .replay)
        }
        .buttonStyle(.glass)
        .focusSection()
    }
}
