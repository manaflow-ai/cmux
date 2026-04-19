import Foundation

/// Determines what should happen to the trailing component of a character pair when deleting the leading component.
public enum CharacterPairTrailingComponentDeletionMode {
    /// Do not delete the trailing component of the character pair when deleting the leading component.
    case disabled
    /// Delete the trailing component when it is immediately following the leading component which is deleted.
    case immediatelyFollowingLeadingComponent
}
