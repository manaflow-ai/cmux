import CoreGraphics

/// Whether a transcript's jump-to-bottom control shows (verify/jump-button.md).
/// The rule the transcript uses today (distance from the bottom > 80 pt,
/// rubber band included); the next commit replaces it.
public struct JumpToBottomVisibility: Equatable, Sendable {
    public static let showDistance: CGFloat = 80
    public static let hideDistance: CGFloat = 80

    public static func next(isShown: Bool, offsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat,
                            keyboardDragging: Bool = false) -> Bool {
        maxOffsetY - offsetY > 80
    }
}
