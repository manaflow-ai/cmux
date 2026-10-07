import QuartzCore
import UIKit

/// Keeps the newest value and applies it on the next display frame, so a
/// burst of snapshots costs one diff per frame. The display link exists
/// only while a value is pending; an idle list has no link and no wakeups.
@MainActor
final class FrameCoalescer<Value> {
    private var pending: Value?
    private var link: CADisplayLink?
    private let apply: (Value) -> Void

    init(apply: @escaping (Value) -> Void) {
        self.apply = apply
    }

    func submit(_ value: Value) {
        pending = value
        guard link == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] in self?.fire() }
        // wakeup-allow: one-shot display link, armed only while a snapshot is pending
        let made = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        made.add(to: .main, forMode: .common)
        link = made
    }

    /// Applies a pending value now (for example before the view disappears).
    func flush() {
        fire()
    }

    func cancel() {
        link?.invalidate()
        link = nil
        pending = nil
    }

    private func fire() {
        link?.invalidate()
        link = nil
        guard let value = pending else { return }
        pending = nil
        apply(value)
    }
}
