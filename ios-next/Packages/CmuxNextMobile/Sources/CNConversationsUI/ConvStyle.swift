#if os(iOS)
import CNCore
import CNDesign
import UIKit

/// Geometry measured from Messages on iOS 27 (reference/imessage.md), with
/// cmux-next colors from `CNDesign` in place of Apple's blue.
struct ConvStyle {
    let palette = CNTheme.shared.palette

    // MARK: List (§1)
    let rowHeight: CGFloat = 86.67
    let rowAvatar: CGFloat = 45
    let rowAvatarX: CGFloat = 26
    let rowAvatarTop: CGFloat = 20
    let rowTextX: CGFloat = 83
    let rowTitleTop: CGFloat = 12
    let rowTrailing: CGFloat = 16
    let dateRightInset: CGFloat = 36.3        // 402 - 365.7
    let chevronSize = CGSize(width: 10.3, height: 14)
    let largeTitleTopFromSafeArea: CGFloat = 57.7   // AX top 119.7 with a 62 pt safe area
    let largeTitleHeight: CGFloat = 40.7
    let titleSeparatorFromSafeArea: CGFloat = 106   // y 168
    let firstRowGap: CGFloat = 8
    let collapseOffset: CGFloat = 54
    let searchHeight: CGFloat = 48
    let searchSideInset: CGFloat = 28
    let searchBottomInset: CGFloat = 28
    let swipeButton: CGFloat = 50
    let swipeGap: CGFloat = 10
    let swipeCardRadius: CGFloat = 26

    // MARK: Thread (§4, §5)
    var bubbleFont: UIFont { .systemFont(ofSize: 17) }
    let bubbleLine: CGFloat = 20
    let bubblePadV: CGFloat = 10
    let bubblePadH: CGFloat = 14
    let bubbleMaxWidth: CGFloat = 280
    let bubbleMinWidth: CGFloat = 48
    let bubbleRadius: CGFloat = 20
    let bubbleMargin: CGFloat = 16
    let tailDepth: CGFloat = 7.3
    let gapSameRun: CGFloat = 4
    let gapNewRun: CGFloat = 10
    let headerAvatar: CGFloat = 60
    let backButton: CGFloat = 44
    let composerField: CGFloat = 40.33
    let plusButton: CGFloat = 40
    let composerMarginIdle: CGFloat = 28
    let composerMarginKeyboard: CGFloat = 16
    let composerGap: CGFloat = 12
    let sendSize = CGSize(width: 38, height: 28)
    let sendInset: CGFloat = 6.3

    // MARK: Colors
    var background: UIColor { palette.background }
    var primary: UIColor { palette.textPrimary }
    var secondary: UIColor { palette.textSecondary }
    var tertiary: UIColor { palette.textTertiary }
    var separator: UIColor { palette.separator }
    var rowHighlight: UIColor { palette.selection }
    var swipeCard: UIColor { palette.control }
    var outgoing: UIColor { palette.outgoingBubble }
    var outgoingText: UIColor { palette.outgoingText }
    var incoming: UIColor { palette.incomingBubble }
    var incomingText: UIColor { palette.incomingText }
    var unreadDot: UIColor { palette.ink }
    var muteAction: UIColor { palette.groupHues[5] }
    var deleteAction: UIColor { palette.danger }
    var unreadAction: UIColor { palette.highlight }
    var pinAction: UIColor { palette.attention }

    func avatarColor(for conversation: Conversation) -> UIColor {
        conversation.kind == .chief ? palette.chiefAvatar : palette.groupHue(for: conversation.id)
    }

    func avatarInk(for conversation: Conversation) -> UIColor {
        conversation.kind == .chief ? palette.ink.withAlphaComponent(0.72) : .white
    }

    static let shared = ConvStyle()
}

extension UIFont {
    static func sf(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { .systemFont(ofSize: size, weight: weight) }
}

/// Builds Liquid Glass surfaces (iOS 26).
@MainActor
func makeGlass(capsule: Bool = true, radius: CGFloat = 0, interactive: Bool = true) -> UIVisualEffectView {
    let effect = UIGlassEffect()
    effect.isInteractive = interactive
    let v = UIVisualEffectView(effect: effect)
    v.cornerConfiguration = capsule ? .capsule() : .corners(radius: .fixed(radius))
    return v
}

/// Relative dates as in the Messages list: time today, "Yesterday", weekday
/// within a week, short date otherwise.
struct ConvDates {
    let calendar = Calendar.current

    func listLabel(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// "**Today** 9:45 PM" separator.
    func separator(_ date: Date, now: Date = Date()) -> NSAttributedString {
        let day: String
        if calendar.isDateInToday(date) { day = String(localized: "Today") }
        else if calendar.isDateInYesterday(date) { day = String(localized: "Yesterday") }
        else if let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, d < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let s = NSMutableAttributedString(string: day, attributes: [.font: UIFont.sf(11, .semibold)])
        s.append(NSAttributedString(string: " " + date.formatted(date: .omitted, time: .shortened), attributes: [.font: UIFont.sf(11)]))
        return s
    }

    func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
#endif
