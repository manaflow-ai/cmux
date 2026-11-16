/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Reader mode: the article of the focused browser tab, read through `page.read`, shown as plain
// text in the app's pane. The "Reader mode" command (palette, CLI, MCP) reads the page and opens
// the pane; the pane's "Read this page" reads again. The last article is kept in app storage so
// the pane still shows it after a reload.

type Block = CmuxPageBlock
type PageRead = CmuxPageRead

const KEY = "last"
const [page, setPage] = signal<PageRead | null>(null)
const [loading, setLoading] = signal(false)
const [error, setError] = signal<string | null>(null)
let restored: Promise<void> | null = null

const message = (e: unknown) => (e instanceof Error ? e.message : String(e))

/** The stored article, read once for every mount; a read that already ran wins. */
function restore() {
  restored ??= (async () => {
    try {
      const last = await cmux.storage.get<PageRead>(KEY)
      if (last && !page()) setPage(last)
    } catch {
      // No storage grant: the pane starts empty.
    }
  })()
  return restored
}

/** Reads the page through `api` (a command's ctx.cmux carries its gesture) and shows it. */
async function read(api: CmuxGlobal, tab?: string): Promise<PageRead> {
  setLoading(true)
  try {
    const value = await api.page.read(tab ? { tab } : {})
    setPage(value)
    setError(null)
    api.storage.set(KEY, value).catch(() => {})
    return value
  } catch (e) {
    setError(message(e))
    throw e
  } finally {
    setLoading(false)
  }
}

/** Command `reader_mode.open`: read the focused browser tab (or `tab`) and show it in the pane. */
export async function open(args: { tab?: string } = {}, ctx?: CmuxCommandContext) {
  const api = ctx?.cmux ?? cmux
  const value = await read(api, args.tab)
  let shown = true
  try {
    await api.actions.run("app.open", { app: cmux.app.id })
  } catch {
    shown = false
  }
  return { title: value.article.title || value.title, url: value.url, blocks: value.article.blocks.length, shown }
}

const openURL = (url: string) => cmux.actions.run("openBrowser", { url })

function blockView(b: Block): CmuxView {
  switch (b.kind) {
    case "heading":
      return Text(b.text).font((b.level ?? 2) <= 1 ? "title2" : (b.level ?? 2) === 2 ? "title3" : "headline")
    case "list_item":
      return HStack({ spacing: 6 }, [Text("•").secondary(), Text(b.text).font("body"), Spacer()])
    case "quote":
      return HStack({ spacing: 8 }, [Rectangle().fill("separator").frame({ width: 3, maxHeight: "infinity" }), Text(b.text).font("body").italic().secondary(), Spacer()])
    case "code":
      return Text(b.text).monospaced().font("callout").padding(8).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6)
    case "image": {
      // The scene kit draws no remote images: an image is its caption, and a click opens it.
      const row = Row({ title: b.text || "Image", subtitle: b.src ?? null, symbol: "photo" })
      return b.src ? row.help(b.src).onTap(() => openURL(b.src!)) : row
    }
    default:
      return HStack([Text(b.text).font("body"), Spacer()])
  }
}

function articleView(p: PageRead): CmuxView {
  const a = p.article
  const meta = [a.byline, a.site].filter((s): s is string => !!s && s.trim() !== "").join(" · ")
  return VStack({ spacing: 10 }, [
    Text(a.title || p.title || p.url).font("title"),
    meta ? Text(meta).font("callout").secondary() : null,
    Text(p.url).font("caption").secondary().lineLimit(1).truncation("middle"),
    Divider(),
    ...a.blocks.map(blockView),
    a.blocks.length === 0 ? EmptyState({ title: "No article text on this page", message: "Reader mode found no paragraphs here.", symbol: "doc.text" }) : null,
    p.links.length > 0 ? Divider() : null,
    p.links.length > 0 ? Text(`Links (${p.links.length})`).font("headline") : null,
    ...p.links.map((l) => Row({ title: l.text || l.href, subtitle: l.href, symbol: "link" }).help(l.href).onTap(() => openURL(l.href)))
  ])
}

/** `cmux.pane/1`: the last article read, with the reader's buttons above it. */
export function renderReader() {
  restore()
  return VStack({ spacing: 12 }, [
    HStack({ spacing: 8 }, [
      Button("Read this page", () => read(cmux).catch(() => {})).disabled(loading),
      Button("Reload", () => read(cmux, page()?.tab).catch(() => {})).disabled(() => loading() || !page()),
      Button("Open original", () => openURL(page()!.url)).disabled(() => !page()),
      Spacer(),
      () => (loading() ? ProgressView() : null)
    ]),
    () => (error() ? EmptyState({ title: "Cannot read this page", message: error()!, symbol: "exclamationmark.triangle" }) : null),
    () => {
      const p = page()
      if (p) return articleView(p)
      if (loading() || error()) return null
      return EmptyState({ title: "No page read yet", message: "Focus a browser tab, then run Reader mode from the command palette or click Read this page.", symbol: "doc.plaintext" })
    }
  ]).padding(16)
}
