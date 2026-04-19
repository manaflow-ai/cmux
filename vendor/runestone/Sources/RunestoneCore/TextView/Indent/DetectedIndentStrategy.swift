import Foundation

/// Indentation strategy detected in text.
///
/// the indentation strategy is detected when creating an instance of ``TextViewState``.
public enum DetectedIndentStrategy {
    /// Indent using tab.
    case tab
    /// Indent using a numer of spaces.
    case space(length: Int)
    /// The indentation strategy could not be determined.
    case unknown
}
