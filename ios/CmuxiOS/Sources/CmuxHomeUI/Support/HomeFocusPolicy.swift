/// Whether compose screens may focus a field (and raise the keyboard) when
/// they appear. The DEBUG gallery turns it off so captures show the screen
/// without a keyboard inset.
@MainActor
enum HomeFocusPolicy {
    static var suppressesAutomaticFocus = false
}
