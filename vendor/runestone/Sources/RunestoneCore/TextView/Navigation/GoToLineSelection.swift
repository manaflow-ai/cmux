import Foundation

/// Amount of text to select when navigating to a line.
public enum GoToLineSelection {
    /// Position the crat at the beginning of the line.
    case beginning
    /// Position the caret at the end of the line.
    case end
    /// Select the entire line.
    case line
}
