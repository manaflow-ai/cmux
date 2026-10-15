#if os(iOS)
import CNCore
import CNDesign
import SwiftUI

/// What to tell the user about a Mac browser tab the phone cannot show.
struct MacBrowserAccessCopy: Equatable {
    var symbol: String
    var headline: String
    var detail: String
    /// The setting to change, as a path ("cmux Settings › …"); nil when
    /// there is nothing to change on the phone's side.
    var path: String?
    var footnote: String?
    /// The status line under the card: the host is watched live.
    var waiting: String?

    init(status: BrowserMacStatus?, isBrowser: Bool, hostName: String, reason: String? = nil) {
        let host = status?.hostName.flatMap { $0.isEmpty ? nil : $0 } ?? (hostName.isEmpty ? "your Mac" : hostName)
        switch (isBrowser, status?.state) {
        case (true, .off?):
            symbol = "safari"
            headline = "Turn on browser access on your Mac"
            detail = "To see this tab here, allow cmux on iPhone to view the browser tabs on \(host)."
            path = "cmux Settings › Allow cmux on iPhone to view browser tabs"
            footnote = status?.restartRequired == true ? "Then restart cmux on \(host)." : nil
            waiting = "Waiting for \(host)"
        case (true, .unsupported?):
            symbol = "arrow.down.app"
            headline = "Update cmux on your Mac"
            detail = "The cmux on \(host) can't share its browser tabs yet. Update it, then turn on browser access."
            path = "cmux Settings › Allow cmux on iPhone to view browser tabs"
            footnote = nil
            waiting = "Waiting for \(host)"
        case (true, .unavailable?):
            symbol = "exclamationmark.triangle"
            headline = "Browser tabs aren't available"
            detail = status?.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux on \(host) has browser access on, but its tabs couldn't be reached."
            path = nil
            footnote = "Restarting cmux on \(host) usually fixes this."
            waiting = "Retrying with \(host)"
        default:
            symbol = isBrowser ? "safari" : "macwindow"
            headline = "Open on your Mac"
            detail = reason.flatMap { $0.isEmpty ? nil : ($0.hasSuffix(".") ? $0 : "\($0).") } ?? "This tab can't be shown on iPhone. It's open in cmux on \(host)."
            path = nil
            footnote = nil
            waiting = nil
        }
    }

}

/// The large glass card shown when a Mac browser tab is opened but cannot be
/// streamed: what to turn on, exactly where, and a live status line that
/// gives way to the page as soon as the Mac allows it.
struct MacBrowserAccessBanner: View {
    var copy: MacBrowserAccessCopy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let style = BrowserStyle.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: copy.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(style.colors.accent)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.tint(style.colors.accent.opacity(0.12)), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(style.colors.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(copy.detail)
                    .font(.subheadline)
                    .foregroundStyle(style.colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let path = copy.path {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "gearshape").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    Text(path)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(style.colors.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.colors.label.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("In cmux Settings on the Mac: \(path)")
            }
            if let footnote = copy.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(style.colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let waiting = copy.waiting {
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                    Text(waiting)
                        .font(.footnote)
                        .foregroundStyle(style.colors.secondaryLabel)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(waiting). The page opens here once it's allowed.")
            }
        }
        .padding(20)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A tab's letter on a tinted tile (a favicon stand-in).
struct TabLetterTile: View {
    var title: String
    var url: String?
    var size: CGFloat

    var body: some View {
        let host = url.flatMap { URL(string: $0)?.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let letter = (host ?? title).first.map { String($0).uppercased() } ?? "?"
        // Stable per site (String.hashValue changes every launch).
        let hue = Double((host ?? title).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(letter)
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.75), in: .rect(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A Mac-only tab opened full screen: its title and address, and the
/// access banner (or a short "open on your Mac" note).
struct MacOnlyPage: View {
    var tab: LayoutTab
    var status: BrowserMacStatus?
    var hostName: String
    var safeTop: CGFloat
    var safeBottom: CGFloat

    private let style = BrowserStyle.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    TabLetterTile(title: tab.title, url: tab.url, size: 64)
                    Text(tab.title.isEmpty ? "Untitled" : tab.title)
                        .font(.headline)
                        .foregroundStyle(style.colors.label)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if let url = tab.url, !url.isEmpty {
                        Text(url)
                            .font(.footnote)
                            .foregroundStyle(style.colors.secondaryLabel)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 24)
                MacBrowserAccessBanner(copy: MacBrowserAccessCopy(status: status, isBrowser: tab.kind == .browser, hostName: hostName, reason: tab.reason))
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, safeTop + 48)
            .padding(.bottom, safeBottom + 90)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(style.colors.startBackground)
    }
}

/// A Mac browser tab the Mac is not showing renders nothing: the opened
/// tab dims its last frame under this card, whose button switches the
/// Mac's pane to the tab. The page goes live as soon as frames arrive.
struct HiddenOnMacOverlay: View {
    var hostName: String
    var safeTop: CGFloat
    var onShow: () -> Void
    private let style = BrowserStyle.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .contentShape(.rect)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "macbook")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(style.colors.accent)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.tint(style.colors.accent.opacity(0.12)), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not showing on your Mac")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(style.colors.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(hostName.isEmpty ? "Your Mac" : hostName) only draws the tab its pane shows. Show this tab there to see it live; the pane on the Mac switches to it.")
                        .font(.subheadline)
                        .foregroundStyle(style.colors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: onShow) {
                    Label("Show on Mac", systemImage: "macbook.and.iphone")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                // The app's tint is the label color (white in dark mode),
                // which left a light label on a white button: use the
                // accent fill with a white label in both appearances.
                .tint(style.colors.accent)
                .accessibilityHint("Switches the Mac's pane to this tab")
                Text("You can bring tabs forward automatically in Settings › Browser.")
                    .font(.footnote)
                    .foregroundStyle(style.colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 420, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
        }
    }
}

#endif
