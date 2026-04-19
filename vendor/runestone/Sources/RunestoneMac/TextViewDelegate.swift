#if canImport(AppKit)
import Foundation

/// Delegate callbacks for editing and selection updates in macOS `TextView`.
public protocol TextViewDelegate: AnyObject {
    /// Called when text changes.
    func textViewDidChange(_ textView: TextView)
    /// Called when selection changes.
    func textViewDidChangeSelection(_ textView: TextView)
    /// Called before replacing text in a range.
    func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool
}

public extension TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {}
    func textViewDidChangeSelection(_ textView: TextView) {}
    func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        true
    }
}
#endif
