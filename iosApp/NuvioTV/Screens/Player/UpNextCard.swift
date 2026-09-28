import SharedCore
import SwiftUI

/// The Up Next card both engines draw bottom-trailing while `NextEpisodeEngine.phase` is not
/// `.hidden` (AES-1): the next episode's still (series artwork when it has none), "Next Episode",
/// the S·E line and title, a countdown ring with the seconds left, and what the remote does.
///
/// Never focusable — the mpv controller owns the remote, and on the native engine the interactive
/// twins are the system contextual actions. Neutral glass (a prompt is an action, not a selection —
/// `PlayerChipStyle`), Theme tokens only. The countdown lives in its own ring, never in a line of
/// text that could truncate it away.
struct UpNextCard: View {
    @ObservedObject var engine: NextEpisodeEngine
    /// Artwork when the next episode has no still of its own (series backdrop, else poster).
    let fallbackArtwork: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardWidth: CGFloat = 920
    private static let artworkSize = CGSize(width: 288, height: 162)
    private static let ringSize: CGFloat = 104
    private static let ringLineWidth: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                artwork
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
                ring
            }
            hints
        }
        .padding(Theme.Spacing.lg)
        .frame(width: Self.cardWidth, alignment: .leading)
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: RoundedRectangle(cornerRadius: Theme.Radius.hero))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Artwork

    private var artworkURL: String? {
        let still: String? = engine.nextVideo?.thumbnail
        if let still, !still.isEmpty { return still }
        return fallbackArtwork
    }

    private var artwork: some View {
        CachedAsyncImage(string: artworkURL)
            .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    // MARK: - Text

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("Next Episode")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            if let season = engine.nextVideo?.season?.value, let episode = engine.nextVideo?.episode?.value {
                // "SxEy", the app's episode code (not localized, like the episode chips).
                Text(verbatim: "S\(season)E\(episode)")
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Text(engine.nextVideo?.title ?? engine.nextEpisodeTitle)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            status
                .padding(.top, Theme.Spacing.xxs)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch engine.phase {
        case .noStream:
            Label("No stream found for the next episode.", systemImage: "exclamationmark.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        case .stillWatching:
            Label("Still watching?", systemImage: "questionmark.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .upNext where engine.isWaitingForSource:
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().scaleEffect(0.6)
                Text("Finding a source\u{2026}")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
        case .upNext where engine.countdownPaused:
            Label("Paused", systemImage: "pause.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .upNext:
            if let source = engine.sourceName, engine.isStreamReady {
                Text(source)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        case .hidden:
            EmptyView()
        }
    }

    /// What the remote does right now (the hint the old one-line caption never had room for).
    private var hints: some View {
        HStack(spacing: Theme.Spacing.xl) {
            switch engine.phase {
            case .stillWatching:
                Text("OK / \u{25BC}: continue")
                Text("Menu: back to details")
            case .noStream:
                Text("OK / Menu: cancel")
                Text("\u{25BC}: choose a source")
            case .upNext, .hidden:
                Text("OK / Menu: cancel")
                Text("\u{25BC}: play now")
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Palette.textSecondary)
        .lineLimit(1)
    }

    // MARK: - Countdown ring

    private var progress: CGFloat {
        guard engine.phase == .upNext, engine.countdownTotal > 0 else { return 0 }
        return CGFloat(engine.countdownRemaining) / CGFloat(engine.countdownTotal)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.textPrimary.opacity(0.2), lineWidth: Self.ringLineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.Palette.textPrimary,
                        style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: engine.countdownRemaining)
            ringCenter
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
    }

    @ViewBuilder
    private var ringCenter: some View {
        switch engine.phase {
        case .upNext where engine.countdownRemaining > 0:
            Text(verbatim: "\(engine.countdownRemaining)")
                .font(Theme.Font.screenTitle.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityLabel(Text("Playing in \(engine.countdownRemaining) s"))
        case .upNext:
            if engine.isStreamReady {
                Image(systemName: PlayerChipStyle.nextSymbol)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            } else {
                ProgressView()
            }
        case .stillWatching:
            Image(systemName: "questionmark")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .noStream:
            Image(systemName: "exclamationmark")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .hidden:
            EmptyView()
        }
    }
}
