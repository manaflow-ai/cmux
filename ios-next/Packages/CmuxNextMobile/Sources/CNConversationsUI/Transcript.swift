#if os(iOS)
import CNCore
import UIKit

// MARK: Bubble shape

/// Messages bubble outline: radius-20 rounded body (a capsule for one line)
/// with an optional tail hooking out of the bottom corner on the sender's
/// side, traced from the 6x reference crops (reference §4 tail table).
func bubblePath(size: CGSize, tail: Bool, outgoing: Bool) -> UIBezierPath {
    let w = size.width, h = size.height
    let r = min(20, h / 2, w / 2)
    let p = UIBezierPath()
    p.move(to: CGPoint(x: r, y: 0))
    p.addLine(to: CGPoint(x: w - r, y: 0))
    p.addArc(withCenter: CGPoint(x: w - r, y: r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: w, y: h - r))
    if tail {
        p.addArc(withCenter: CGPoint(x: w - r, y: h - r), radius: r, startAngle: 0, endAngle: .pi / 3, clockwise: true)
        p.addCurve(to: CGPoint(x: w - 8.5, y: h + 6.2), controlPoint1: CGPoint(x: w - 10.6, y: h + 0.4), controlPoint2: CGPoint(x: w - 10.5, y: h + 4.4))
        p.addCurve(to: CGPoint(x: w - 11.2, y: h + 6.4), controlPoint1: CGPoint(x: w - 8.2, y: h + 7.6), controlPoint2: CGPoint(x: w - 9.9, y: h + 7.6))
        p.addCurve(to: CGPoint(x: w - 20.5, y: h), controlPoint1: CGPoint(x: w - 14.2, y: h + 5.2), controlPoint2: CGPoint(x: w - 17.6, y: h + 1.8))
    } else {
        p.addArc(withCenter: CGPoint(x: w - r, y: h - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
    }
    p.addLine(to: CGPoint(x: r, y: h))
    p.addArc(withCenter: CGPoint(x: r, y: h - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    p.addLine(to: CGPoint(x: 0, y: r))
    p.addArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
    p.close()
    if !outgoing {
        p.apply(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
    }
    return p
}

/// A bubble: shape layer plus text, sized by its bounds (body only; the tail
/// draws below the bounds).
final class BubbleView: UIView {
    let shape = CAShapeLayer()
    let label = UILabel()
    var tail = false { didSet { setNeedsLayout() } }
    var outgoing = true { didSet { setNeedsLayout() } }
    var fill: UIColor = .black { didSet { updateFill() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(shape)
        label.numberOfLines = 0
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: BubbleView, _: UITraitCollection) in v.updateFill() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateFill() {
        shape.fillColor = fill.resolvedColor(with: traitCollection).cgColor
    }

    /// Lays the text out at the measured padding; `textScaleY` squashes it
    /// during the send flight.
    var textScaleY: CGFloat = 1 { didSet { setNeedsLayout() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = bubblePath(size: bounds.size, tail: tail, outgoing: outgoing).cgPath
        CATransaction.commit()
        let s = ConvStyle.shared
        let natural = label.attributedText.map { TranscriptMetrics.textSize($0, maxWidth: s.bubbleMaxWidth - 2 * s.bubblePadH) } ?? .zero
        label.transform = .identity
        label.frame = CGRect(x: s.bubblePadH, y: (bounds.height - natural.height) / 2, width: natural.width + 1, height: natural.height)
        if textScaleY != 1 { label.transform = CGAffineTransform(scaleX: 1, y: textScaleY) }
    }
}

// MARK: Measurement

struct TranscriptMetrics {
    static func bubbleText(_ text: String, color: UIColor) -> NSAttributedString {
        let s = ConvStyle.shared
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = s.bubbleLine
        p.maximumLineHeight = s.bubbleLine
        p.lineBreakMode = .byWordWrapping
        let font = s.bubbleFont
        return ConvMarkdown.attributed(text, base: [
            .font: font, .foregroundColor: color, .paragraphStyle: p,
            .baselineOffset: (s.bubbleLine - font.lineHeight) / 2,
        ], font: font)
    }

    static func textSize(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let r = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: max(20, (r.height / 20).rounded() * 20))
    }

    static func bubbleSize(_ text: String) -> CGSize {
        let s = ConvStyle.shared
        let t = textSize(bubbleText(text, color: .black), maxWidth: s.bubbleMaxWidth - 2 * s.bubblePadH)
        return CGSize(width: max(s.bubbleMinWidth, t.width + 2 * s.bubblePadH), height: t.height + 2 * s.bubblePadV)
    }

    /// 1–3 emoji and nothing else render large without a bubble.
    static func emojiCount(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return nil }
        for ch in t {
            guard let first = ch.unicodeScalars.first else { return nil }
            let isEmoji = first.properties.isEmojiPresentation || (first.properties.isEmoji && ch.unicodeScalars.count > 1)
            if !isEmoji { return nil }
        }
        return t.count
    }

    /// Point size whose glyph ink is ~69 pt (one emoji) or ~48 pt (two or three).
    static func emojiFont(count: Int) -> UIFont { .systemFont(ofSize: count == 1 ? 58 : 40) }
}

// MARK: Rows

enum TranscriptRowKind: Hashable {
    case intro(title: String, subtitle: String)
    case time(Date)
    case senderName(String)
    case bubble(Message, tail: Bool)
    case emoji(Message)
    case receipt(String)
    case typing
}

struct TranscriptRow: Hashable {
    var id: String
    var kind: TranscriptRowKind
    var frame: CGRect
    /// The body frame for bubbles (frame may include the tail).
    var body: CGRect
    var outgoing: Bool
    var time: Date?
}

func transcriptKey(_ m: Message) -> String { m.clientId ?? m.id }

/// Computes every row frame top-down (content coordinates, width = view).
struct TranscriptBuilder {
    var width: CGFloat
    var isGroup: Bool
    var introTitle: String
    var introSubtitle: String

    func build(messages: [Message], typing: Bool) -> (rows: [TranscriptRow], height: CGFloat) {
        let s = ConvStyle.shared
        var rows: [TranscriptRow] = []
        var y: CGFloat = 0
        rows.append(TranscriptRow(id: "intro", kind: .intro(title: introTitle, subtitle: introSubtitle),
                                  frame: CGRect(x: 0, y: 0, width: width, height: 26.6), body: .zero, outgoing: false, time: nil))
        y = 26.6
        var lastBottom: CGFloat = y
        var lastWasEmoji = false
        // The receipt goes under my latest message when nothing newer came in.
        let receiptTarget: Message? = {
            let lastOther = messages.lastIndex(where: { !$0.sender.isMe }) ?? -1
            // Messages shows no "Sent" state: the receipt stays on the previous
            // message until the new one is delivered (or fails).
            let shown: Set<MessageStatus> = [.delivered, .read, .failed]
            let mine = messages.enumerated().filter { $0.element.sender.isMe && $0.offset > lastOther && shown.contains($0.element.status) }
            return mine.last?.element
        }()

        for (i, m) in messages.enumerated() {
            let prev = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let newTimeGroup = prev.map { m.sentAt - $0.sentAt >= 3_600_000 || !Calendar.current.isDate($0.sentDate, inSameDayAs: m.sentDate) } ?? true
            let senderChanged = prev.map { $0.sender.id != m.sender.id } ?? true
            let emoji = TranscriptMetrics.emojiCount(m.text)
            if newTimeGroup {
                y = lastBottom + (prev == nil ? 14 : 16)
                rows.append(TranscriptRow(id: "time-" + transcriptKey(m), kind: .time(m.sentDate),
                                          frame: CGRect(x: 0, y: y, width: width, height: 13.3), body: .zero, outgoing: false, time: nil))
                y += 13.3 + 8
            } else if emoji != nil || lastWasEmoji {
                y = lastBottom + 12
            } else {
                y = lastBottom + (senderChanged ? s.gapNewRun : s.gapSameRun)
            }
            if isGroup, !m.sender.isMe, senderChanged || newTimeGroup {
                rows.append(TranscriptRow(id: "name-" + transcriptKey(m), kind: .senderName(m.sender.name),
                                          frame: CGRect(x: 0, y: y, width: width, height: 13.3), body: .zero, outgoing: false, time: nil))
                y += 13.3 + 2
            }
            let key = transcriptKey(m)
            if let n = emoji {
                let font = TranscriptMetrics.emojiFont(count: n)
                let size = (m.text as NSString).size(withAttributes: [.font: font])
                let w = ceil(size.width), h = ceil(font.lineHeight)
                let x = m.sender.isMe ? width - 17 - w : 17
                let f = CGRect(x: 0, y: y, width: width, height: h)
                rows.append(TranscriptRow(id: "msg-" + key, kind: .emoji(m), frame: f, body: CGRect(x: x, y: y, width: w, height: h),
                                          outgoing: m.sender.isMe, time: m.sentDate))
                y += h
                lastWasEmoji = true
            } else {
                let size = TranscriptMetrics.bubbleSize(m.text)
                let nextSameRun = next.map { $0.sender.id == m.sender.id && $0.sentAt - m.sentAt < 3_600_000 && TranscriptMetrics.emojiCount($0.text) == nil } ?? false
                let tail = !nextSameRun
                let x = m.sender.isMe ? width - s.bubbleMargin - size.width : s.bubbleMargin
                let body = CGRect(x: x, y: y, width: size.width, height: size.height)
                rows.append(TranscriptRow(id: "msg-" + key, kind: .bubble(m, tail: tail),
                                          frame: CGRect(x: 0, y: y, width: width, height: size.height + (tail ? s.tailDepth : 0)),
                                          body: body, outgoing: m.sender.isMe, time: m.sentDate))
                y += size.height
                lastWasEmoji = false
                if let target = receiptTarget, target.id == m.id {
                    let text: String
                    switch m.status {
                    case .read: text = String(localized: "Read")
                    case .failed: text = String(localized: "Not Delivered")
                    case .delivered: text = String(localized: "Delivered")
                    default: text = String(localized: "Delivered")
                    }
                    // Ink top ~8 pt under the body, right edge 21 pt inside the bubble.
                    let rf = CGRect(x: 0, y: y + 5.5, width: body.maxX - 21, height: 13.3)
                    rows.append(TranscriptRow(id: "receipt", kind: .receipt(text), frame: rf, body: rf, outgoing: true, time: nil))
                    y = rf.maxY
                }
            }
            lastBottom = y
        }
        if typing {
            let y0 = lastBottom + s.gapNewRun
            let body = CGRect(x: s.bubbleMargin, y: y0, width: 60, height: 40)
            rows.append(TranscriptRow(id: "typing", kind: .typing, frame: CGRect(x: 0, y: y0, width: width, height: 40 + 10),
                                      body: body, outgoing: false, time: nil))
            lastBottom = y0 + 40
        }
        return (rows, lastBottom + 12)
    }
}

// MARK: Layout

final class TranscriptAttributes: UICollectionViewLayoutAttributes {
    var reveal: CGFloat = 0
    var hiddenBody = false

    override func copy(with zone: NSZone? = nil) -> Any {
        let c = super.copy(with: zone) as! TranscriptAttributes
        c.reveal = reveal
        c.hiddenBody = hiddenBody
        return c
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TranscriptAttributes else { return false }
        return o.reveal == reveal && o.hiddenBody == hiddenBody && super.isEqual(object)
    }
}

/// Positions rows at precomputed frames; the swipe-to-reveal offset and the
/// "body hidden during the send flight" flag ride on the attributes.
final class TranscriptLayout: UICollectionViewLayout {
    var rows: [TranscriptRow] = []
    var contentHeight: CGFloat = 0
    var reveal: CGFloat = 0
    var hiddenIds: Set<String> = []
    /// Items that fade in (new time separators) or pop in (incoming bubbles, typing).
    var fadeInIds: Set<String> = []
    var popInIds: Set<String> = []
    private var index: [String: Int] = [:]
    var idForIndexPath: (IndexPath) -> String? = { _ in nil }

    override class var layoutAttributesClass: AnyClass { TranscriptAttributes.self }

    func setRows(_ rows: [TranscriptRow], height: CGFloat) {
        self.rows = rows
        contentHeight = height
        index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    }

    func row(_ id: String) -> TranscriptRow? { index[id].map { rows[$0] } }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    private func attributes(_ ip: IndexPath, _ row: TranscriptRow) -> TranscriptAttributes {
        let a = TranscriptAttributes(forCellWith: ip)
        a.frame = row.frame
        a.reveal = reveal
        a.hiddenBody = hiddenIds.contains(row.id)
        a.zIndex = row.id == "typing" ? 1 : 0
        return a
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let cv = collectionView, cv.numberOfSections > 0 else { return [] }
        var out: [UICollectionViewLayoutAttributes] = []
        let count = cv.numberOfItems(inSection: 0)
        for i in 0..<count {
            let ip = IndexPath(item: i, section: 0)
            guard let id = idForIndexPath(ip), let row = row(id) else { continue }
            if row.frame.insetBy(dx: 0, dy: -12).intersects(rect) { out.append(attributes(ip, row)) }
        }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let id = idForIndexPath(ip), let row = row(id) else { return nil }
        return attributes(ip, row)
    }

    override func initialLayoutAttributesForAppearingItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let a = layoutAttributesForItem(at: ip)?.copy() as? TranscriptAttributes, let id = idForIndexPath(ip) else { return nil }
        if fadeInIds.contains(id) {
            a.alpha = 0
        } else if popInIds.contains(id), let row = row(id) {
            let s: CGFloat = 0.6
            let anchorX = row.outgoing ? row.body.maxX : row.body.minX
            let dx = (anchorX - a.frame.midX) * (1 - s)
            let dy = (row.body.maxY - a.frame.midY) * (1 - s)
            a.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
            a.alpha = 0
        } else if hiddenIds.contains(id) {
            a.alpha = 1
        } else {
            a.alpha = 0
        }
        return a
    }

    override func finalLayoutAttributesForDisappearingItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        let a = super.finalLayoutAttributesForDisappearingItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes
        a?.alpha = 0
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

// MARK: Cells

/// Every transcript row type in one cell: the content view slides left by
/// `reveal` while per-message timestamps stay fixed at the right edge.
final class TranscriptCell: UICollectionViewCell {
    static let reuse = "transcript"
    let slider = UIView()
    let bubble = BubbleView()
    private let emoji = UILabel()
    private let text = UILabel()
    private let subtext = UILabel()
    private let timeLabel = UILabel()
    private let typing = TypingBubble()
    private(set) var row: TranscriptRow?
    private var reveal: CGFloat = 0
    private var hiddenBody = false
    private var failedDim = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let s = ConvStyle.shared
        contentView.addSubview(slider)
        for v in [bubble, emoji, text, subtext, typing] as [UIView] { slider.addSubview(v) }
        contentView.addSubview(timeLabel)
        timeLabel.font = .sf(11)
        timeLabel.textColor = s.secondary
        timeLabel.textAlignment = .right
        text.textAlignment = .center
        text.textColor = s.secondary
        subtext.textAlignment = .center
        subtext.textColor = s.secondary
        subtext.font = .sf(11)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: TranscriptRow) {
        self.row = row
        failedDim = false
        let s = ConvStyle.shared
        bubble.isHidden = true
        emoji.isHidden = true
        text.isHidden = true
        subtext.isHidden = true
        typing.isHidden = true
        timeLabel.isHidden = row.time == nil
        text.textColor = s.secondary
        timeLabel.text = row.time.map { ConvDates().time($0) }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        switch row.kind {
        case .intro(let title, let subtitle):
            text.isHidden = false
            subtext.isHidden = false
            text.font = .sf(11)
            text.text = title
            text.textAlignment = .center
            subtext.text = subtitle
            accessibilityLabel = [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        case .time(let date):
            text.isHidden = false
            let sep = NSMutableAttributedString(attributedString: ConvDates().separator(date))
            sep.addAttribute(.foregroundColor, value: s.secondary, range: NSRange(location: 0, length: sep.length))
            text.attributedText = sep
            text.textAlignment = .center
            accessibilityLabel = text.attributedText?.string
        case .senderName(let name):
            text.isHidden = false
            text.font = .sf(11)
            text.text = name
            text.textAlignment = .left
            accessibilityLabel = name
        case .receipt(let label):
            text.isHidden = false
            text.font = .sf(11, .semibold)
            text.text = label
            text.textAlignment = .right
            accessibilityLabel = label
        case .bubble(let m, let tail):
            bubble.isHidden = false
            bubble.outgoing = m.sender.isMe
            bubble.tail = tail
            bubble.fill = m.sender.isMe ? s.outgoing : s.incoming
            bubble.label.attributedText = TranscriptMetrics.bubbleText(m.text, color: m.sender.isMe ? s.outgoingText : s.incomingText)
            failedDim = m.status == .failed
            accessibilityLabel = (m.sender.isMe ? String(localized: "You") : m.sender.name) + ", " + m.text
        case .emoji(let m):
            emoji.isHidden = false
            emoji.font = TranscriptMetrics.emojiFont(count: TranscriptMetrics.emojiCount(m.text) ?? 1)
            emoji.text = m.text
            accessibilityLabel = (m.sender.isMe ? String(localized: "You") : m.sender.name) + ", " + m.text
        case .typing:
            typing.isHidden = false
            typing.startAnimating()
            accessibilityLabel = String(localized: "Typing")
        }
        applyBodyVisibility()
        setNeedsLayout()
    }

    override func apply(_ attrs: UICollectionViewLayoutAttributes) {
        super.apply(attrs)
        guard let a = attrs as? TranscriptAttributes else { return }
        reveal = a.reveal
        hiddenBody = a.hiddenBody
        applyReveal()
        applyBodyVisibility()
    }

    /// Layout attributes can be applied before or after `configure` (dequeue
    /// applies them first), so both paths go through here.
    private func applyBodyVisibility() {
        bubble.alpha = hiddenBody ? 0 : (failedDim ? 0.55 : 1)
        emoji.alpha = hiddenBody ? 0 : 1
    }

    private func applyReveal() {
        slider.transform = CGAffineTransform(translationX: -reveal, y: 0)
        timeLabel.alpha = clamp01(reveal / 40)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        slider.transform = .identity
        slider.frame = contentView.bounds
        let local = row.body.offsetBy(dx: -row.frame.minX, dy: -row.frame.minY)
        let w = contentView.bounds.width
        switch row.kind {
        case .intro:
            text.frame = CGRect(x: 0, y: 0, width: w, height: 13.3)
            subtext.frame = CGRect(x: 0, y: 13.3, width: w, height: 13.3)
        case .time:
            text.frame = CGRect(x: 0, y: 0, width: w, height: 13.3)
        case .senderName:
            text.frame = CGRect(x: ConvStyle.shared.bubbleMargin + 12, y: 0, width: w - 60, height: 13.3)
        case .receipt:
            text.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: 13.3)
        case .bubble:
            bubble.frame = local
        case .emoji:
            emoji.frame = local
        case .typing:
            typing.frame = local
        }
        if row.time != nil {
            timeLabel.frame = CGRect(x: w - 11 - 60, y: local.midY - 6.65, width: 60, height: 13.3)
        }
        applyReveal()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        typing.stopAnimating()
        text.attributedText = nil
    }
}

/// Typing indicator: received-gray capsule with a detached "thought" dot and
/// three 9 pt dots pulsing in sequence (period 1.2 s, 0.3 s phase).
final class TypingBubble: UIView {
    private let body = UIView()
    private let big = UIView()
    private let small = UIView()
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let s = ConvStyle.shared
        for v in [small, big, body] {
            v.backgroundColor = s.incoming
            addSubview(v)
        }
        for _ in 0..<3 {
            let d = UIView()
            d.backgroundColor = s.secondary
            d.layer.cornerRadius = 4.5
            body.addSubview(d)
            dots.append(d)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        body.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 40)
        body.layer.cornerRadius = 20
        big.frame = CGRect(x: -1, y: 28, width: 14, height: 14)
        big.layer.cornerRadius = 7
        small.frame = CGRect(x: -6, y: 41, width: 6, height: 6)
        small.layer.cornerRadius = 3
        let total: CGFloat = 3 * 9 + 2 * 4
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(i) * 13, y: 15.5, width: 9, height: 9)
        }
    }

    func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            for d in dots { d.alpha = 0.6 }
            return
        }
        let now = CACurrentMediaTime()
        for (i, d) in dots.enumerated() {
            d.layer.removeAllAnimations()
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.4, 1, 0.4, 0.4]
            opacity.keyTimes = [0, 0.25, 0.5, 1]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1, 1.15, 1, 1]
            scale.keyTimes = [0, 0.25, 0.5, 1]
            let g = CAAnimationGroup()
            g.animations = [opacity, scale]
            g.duration = 1.2
            g.repeatCount = .infinity
            g.beginTime = now + Double(i) * 0.3
            g.fillMode = .backwards
            d.layer.opacity = 0.4
            d.layer.add(g, forKey: "pulse")
        }
    }

    func stopAnimating() {
        for d in dots { d.layer.removeAllAnimations() }
    }
}
#endif
