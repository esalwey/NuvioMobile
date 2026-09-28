import SwiftUI

/// SRC-1 (FEAT-37): a 10-foot on-screen keyboard that edits the Search query directly, so results
/// update while typing — `SearchViewModel.queryChanged` debounces the search by 400 ms — instead of
/// only once tvOS's full-screen keyboard is dismissed. The text field above it still opens the
/// system keyboard (dictation, typing from an iPhone) when selected.
///
/// Focus: plain rows of buttons. Left/Right walk a row, Up/Down move between rows, and Down from the
/// last row leaves for the results; the call site wraps the block in a `.focusSection()`.
struct SearchKeyboard: View {
    @Binding var text: String

    private static let keyRows: [[String]] = [
        ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"],
        ["n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"],
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "'", "-", ":"],
        // French titles (Amélie, Ça, Les Misérables…): catalog searches match accents as typed.
        ["é", "è", "ê", "à", "â", "ç", "ù", "û", "ô", "î", "ï", "ë", "œ"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Self.keyRows, id: \.self) { row in
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(row, id: \.self) { key in
                        SearchKeyboardKey(accessibilityText: key, action: { text.append(key) }) {
                            Text(key.uppercased())
                        }
                    }
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                SearchKeyboardKey(accessibilityText: String(localized: "Space"), width: 260, action: { text.append(" ") }) {
                    Text("Space")
                }
                SearchKeyboardKey(accessibilityText: String(localized: "Backspace"), width: 140, action: {
                    if !text.isEmpty { text.removeLast() }
                }) {
                    Image(systemName: "delete.left")
                }
                SearchKeyboardKey(accessibilityText: String(localized: "Clear All"), width: 140, action: { text = "" }) {
                    Image(systemName: "xmark")
                }
            }
        }
    }
}

/// One key: a focusable capsule (the stock `.chip` focus lift) sized for the 10-foot grid.
private struct SearchKeyboardKey<Label: View>: View {
    let accessibilityText: String
    var width: CGFloat = 64
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(Theme.Font.body)
                .frame(width: width, height: 64)
        }
        .buttonStyle(.chip)
        .accessibilityLabel(Text(accessibilityText))
    }
}
