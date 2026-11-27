/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Quick Links: a declarative app. The scene (VStack, Row, EmptyState) is data;
// cmux draws it natively in the sidebar section and in the pane.

interface Link { title: string; url: string }

export function parseLinks(text: string): Link[] {
  return text
    .split("\n")
    .map((line) => line.split("|").map((part) => part.trim()))
    .filter((parts) => parts.length === 2 && /^https:\/\//.test(parts[1]!) && parts[0]!.length > 0)
    .map(([title, url]) => ({ title: title!, url: url! }))
}

const links = computed(() => parseLinks(String(cmux.app.settings().links ?? "")))

function open(url: string) {
  cmux.actions.run("openBrowser", { url })
}

function rows() {
  return VStack({ spacing: 2 }, [
    ForEach({ items: links, key: (l) => l.url }, (l) =>
      Row({ title: () => l().title, subtitle: () => l().url.replace("https://", ""), symbol: () => "link" })
        .help(() => l().url)
        .onTap(() => open(l().url))
    ),
    () => (links().length === 0 ? EmptyState({ title: "No links yet", message: "Add links in Settings > Apps > Quick Links.", symbol: "link.badge.plus" }) : null)
  ])
}

export function renderSection() {
  return rows()
}

export function renderPane() {
  return rows()
}
