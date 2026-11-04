import SwiftUI

/// A "done" button over a numeric keyboard.
///
/// `.decimalPad` and `.numberPad` have no return key, so the only way off them is a tap outside
/// the field - which on a form crowded with other controls means tapping something you did not
/// mean to. This puts a real dismiss button on the keyboard itself.
struct NumericKeyboardDoneButton: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .toolbar {
                // Gated on THIS field's focus. Keyboard toolbars from every field in the
                // hierarchy are merged into one bar, so a screen with two numeric fields - the
                // KAS/fiat converter has exactly that - drew two checkmarks side by side.
                if isFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            isFocused = false
                        } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("Done editing")
                    }
                }
            }
    }
}

extension View {
    /// Adds a checkmark to the numeric keyboard that dismisses it. See
    /// `NumericKeyboardDoneButton`.
    func numericKeyboardDoneButton() -> some View {
        modifier(NumericKeyboardDoneButton())
    }
}
