import CNCore
import Foundation

/// A site for the Favorites grid, derived from the open tabs: one per site
/// (host without "www."), named like Safari's tiles.
struct FavoriteSite: Identifiable, Hashable {
    var id: String { host }
    var host: String
    var url: String
    var name: String
    var monogram: String

    static func from(_ tabs: [BrowserTab]) -> [FavoriteSite] {
        var seen = Set<String>()
        var out: [FavoriteSite] = []
        for tab in tabs {
            guard let comps = URLComponents(string: tab.url), let scheme = comps.scheme, scheme.hasPrefix("http"),
                  let host = comps.host, !host.isEmpty else { continue }
            let display = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard seen.insert(display).inserted else { continue }
            let parts = display.split(separator: ".")
            let base = parts.count >= 2 ? String(parts[parts.count - 2]) : display
            let name = base.prefix(1).uppercased() + base.dropFirst()
            out.append(FavoriteSite(host: display, url: "\(scheme)://\(host)", name: name, monogram: String(name.prefix(1))))
        }
        // Sites whose short names collide (example.com, example.net and
        // example.org were all "Example") are named by their host instead,
        // so every tile reads differently.
        var counts: [String: Int] = [:]
        for site in out { counts[site.name, default: 0] += 1 }
        for i in out.indices where counts[out[i].name, default: 0] > 1 { out[i].name = out[i].host }
        return out
    }
}

#if os(iOS)
import SwiftUI

/// New-tab start page: Favorites grid of the sites open on the Mac.
struct StartPageView: View {
    var tabs: [BrowserTab]
    var safeTop: CGFloat
    var onOpen: (String) -> Void

    private let style = BrowserStyle.shared

    var body: some View {
        GeometryReader { geo in
            let sites = FavoriteSite.from(tabs)
            let tile = style.metrics.favoriteTile
            let pitch = (geo.size.width - 2 * 16 - tile) / 3
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Favorites")
                        .chromeFont(22, weight: .bold, cap: ChromeType.pageCap)
                        .foregroundStyle(style.colors.label)
                        .frame(minHeight: 34, alignment: .leading)
                        .padding(.leading, 16)
                        .accessibilityAddTraits(.isHeader)
                    if sites.isEmpty {
                        Text("Sites open on your Mac appear here.")
                            .chromeFont(15, cap: ChromeType.pageCap)
                            .foregroundStyle(style.colors.secondaryLabel)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    } else {
                        let rows = stride(from: 0, to: sites.count, by: 4).map { Array(sites[$0..<min($0 + 4, sites.count)]) }
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(rows, id: \.first!.id) { row in
                                HStack(spacing: pitch - tile) {
                                    ForEach(row) { site in favorite(site, tile: tile) }
                                }
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, safeTop + 16)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(style.colors.startBackground)
    }

    private func favorite(_ site: FavoriteSite, tile: CGFloat) -> some View {
        Button { onOpen(site.url) } label: {
            VStack(spacing: 8) {
                Text(site.monogram)
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: tile, height: tile)
                    .background(style.colors.favoriteTile, in: .rect(cornerRadius: style.metrics.favoriteRadius, style: .continuous))
                Text(site.name)
                    .chromeFont(12, weight: .medium)
                    .foregroundStyle(style.colors.label)
                    .lineLimit(1)
                    .frame(width: tile + 20)
            }
            .frame(width: tile)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(site.name)
    }
}

/// Completion list while typing in the address field (section 5.2).
struct AddressSuggestions: View {
    var query: String
    var tabs: [BrowserTab]
    var activeTabId: String?
    var safeTop: CGFloat
    var onSwitch: (String) -> Void
    var onGo: (String) -> Void

    private let style = BrowserStyle.shared

    private var matches: [BrowserTab] {
        let q = query.lowercased()
        return tabs.filter { $0.id != activeTabId && ($0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)) }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if !matches.isEmpty {
                    header("Switch to Tab")
                    ForEach(matches) { tab in
                        Button { onSwitch(tab.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "square.on.square").font(.system(size: 17))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(style.colors.secondaryLabel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.title.isEmpty ? tab.displayHost : tab.title)
                                        .chromeFont(17, weight: .semibold, cap: ChromeType.pageCap).lineLimit(1)
                                        .foregroundStyle(style.colors.label)
                                    Text("\(tab.displayHost) · Opened Tab")
                                        .chromeFont(13, cap: ChromeType.pageCap).lineLimit(1)
                                        .foregroundStyle(style.colors.secondaryLabel)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 57)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                header("Search")
                row(symbol: "magnifyingglass", text: query) { onGo(query) }
                if BrowserModel.normalize(query).hasPrefix("https://") && !query.contains(" ") && query.contains(".") {
                    row(symbol: "globe", text: "Go to \(query)") { onGo(query) }
                }
            }
            .padding(.top, safeTop + 8)
            .padding(.bottom, 400)
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.never)
        .background(style.colors.startBackground)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .chromeFont(15, weight: .semibold, cap: ChromeType.pageCap)
            .foregroundStyle(style.colors.secondaryLabel)
            .padding(.horizontal, 16)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }

    private func row(symbol: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 17))
                    .foregroundStyle(style.colors.secondaryLabel)
                    .frame(width: 30)
                    .padding(.leading, 3)
                Text(text).chromeFont(17, cap: ChromeType.pageCap).lineLimit(1)
                    .foregroundStyle(style.colors.label)
                    .padding(.leading, 15)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
