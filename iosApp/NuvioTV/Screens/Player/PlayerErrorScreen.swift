import Foundation
import SwiftUI
import UIKit

/// Why the mpv player can't show the stream (PLY-1). Until this existed a failed load only reached
/// the console: the spinner stayed up for good, with no message and no way on.
struct PlayerPlaybackError: Equatable {
    enum Kind: Equatable {
        /// mpv gave up on the file (END_FILE with an error): an expired or refused link, a missing
        /// file, an unsupported format.
        case failed
        /// Nothing playable arrived in time — a source that accepts the connection but never delivers
        /// data raises neither FILE_LOADED nor END_FILE. The load keeps going underneath: the card
        /// goes away by itself if the file loads after all.
        case timedOut
        /// The stream reached its end a few seconds after it started: it dropped or is truncated.
        case endedEarly
        /// The stream ended mid-way, well short of its duration: the connection dropped or the link
        /// expired (FFmpeg ends the file there rather than reporting an error).
        case dropped
        /// A short error/placeholder clip played instead of the video (a debrid "not cached" notice).
        case placeholder
    }

    let kind: Kind
    /// Technical detail under the explanation (HTTP status, else mpv's own error text), if any.
    var detail: String? = nil

    var message: String {
        switch kind {
        case .failed:
            return String(localized: "The source didn’t deliver a playable video. The link may have expired, or the file may be unavailable or unsupported.")
        case .timedOut:
            return String(localized: "The source isn’t responding — it may be overloaded or offline. Playback starts on its own if it answers.")
        case .endedEarly:
            return String(localized: "The stream stopped right after it started. The file may be incomplete, or the connection dropped.")
        case .dropped:
            return String(localized: "The stream stopped before the end. The connection may have dropped, or the link may have expired. Retry picks up where it stopped.")
        case .placeholder:
            return String(localized: "The source played a short clip instead of the video — often a notice from the debrid service that the file isn’t ready yet.")
        }
    }

    /// The detail line for an END_FILE error: the HTTP status the core logged while opening the file
    /// (the usual reason — an expired debrid link answers 403/404), else mpv's error string.
    static func detail(httpStatus: Int?, mpvError: String?) -> String? {
        if let status = httpStatus {
            switch status {
            case 401, 403:
                return String(localized: "The server refused access (HTTP \(status)). The link may have expired.")
            case 404, 410:
                return String(localized: "The file is no longer on the server (HTTP \(status)).")
            case 500...599:
                return String(localized: "The server ran into an error (HTTP \(status)).")
            default:
                return String(localized: "The server answered with an error (HTTP \(status)).")
            }
        }
        guard let mpvError, !mpvError.isEmpty else { return nil }
        return "mpv: \(mpvError)"
    }

    /// The status of an FFmpeg `HTTP error 403 Forbidden` log line (nil for any other line). Runs on
    /// the mpv event queue.
    nonisolated static func httpStatus(inLogLine line: String) -> Int? {
        guard let marker = line.range(of: "HTTP error ") else { return nil }
        let digits = line[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 3, let status = Int(digits), (400...599).contains(status) else { return nil }
        return status
    }
}

/// Error card over the mpv player (PLY-1): what went wrong, then the way on — another source (the
/// default: an expired or refused link rarely recovers), the same source again, or, while a slow
/// source is still being waited on, more waiting. Menu leaves the player
/// (`PlayerErrorHostController`).
struct PlayerErrorScreen: View {
    let error: PlayerPlaybackError
    /// What was playing ("S1E3 · Title", or the movie's title).
    let title: String
    /// A stream picker is behind the player. Without one, the first button just leaves the player.
    let canChooseSource: Bool
    let onChooseSource: () -> Void
    let onRetry: () -> Void
    let onKeepWaiting: () -> Void

    /// Focus targets (internal, not private: it types the `@FocusState` below, and the memberwise
    /// initializer must stay internal for the player controller).
    enum Target: Hashable {
        case chooseSource, retry, keepWaiting
    }

    @FocusState private var focus: Target?

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Can’t Play This Source")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(.white)
                        if !title.isEmpty {
                            Text(verbatim: title)
                                .font(Theme.Font.body)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
                Text(verbatim: error.message)
                    .font(Theme.Font.body)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = error.detail {
                    Text(verbatim: detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                // No foreground style over the buttons: the glass style colours its own labels (a
                // forced white would vanish on the near-white focus platter).
                buttons
                    .padding(.top, Theme.Spacing.xs)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        }
        // Drawn over a dark video whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .defaultFocus($focus, .chooseSource)
        .onAppear { DispatchQueue.main.async { focus = .chooseSource } }
    }

    private var buttons: some View {
        let chooseTitle = canChooseSource ? String(localized: "Choose Another Source") : String(localized: "Back")
        return HStack(spacing: Theme.Spacing.md) {
            Button(action: onChooseSource) {
                Label(chooseTitle, systemImage: canChooseSource ? "list.bullet" : "chevron.backward")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .focused($focus, equals: .chooseSource)
            Button(action: onRetry) {
                Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .focused($focus, equals: .retry)
            if error.kind == .timedOut {
                Button(action: onKeepWaiting) {
                    Label(String(localized: "Keep Waiting"), systemImage: "hourglass")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .focused($focus, equals: .keepWaiting)
            }
        }
        .buttonStyle(.glass)
        .focusSection()
    }
}

/// Presents `PlayerErrorScreen` over the mpv player — `.overFullScreen`, like the top panel, so the
/// player underneath gets no disappearance callbacks: its session (progress, Trakt, display mode,
/// the state timer) is still alive for "Retry", and a late load can simply take the card away.
/// Menu leaves the player; it is handled here so it can't pop the card alone and strand a dead
/// player behind it.
final class PlayerErrorHostController: UIHostingController<PlayerErrorScreen> {
    var onMenu: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.error"
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Menu acts on its release (below): the card goes away before the player does, and a release
        // arriving after that would reach whatever is underneath as half a press.
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu?()
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
