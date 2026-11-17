#!/usr/bin/env bun
// Screenshots of the preview page (fixtures, no cmux): each design and each state, light and dark,
// plus gallery.html that shows them side by side. Run from webviews/ (its Playwright):
//   cd webviews && bun ../first-party-apps/rfd-reader/preview/shoot.ts OUT_DIR
import { mkdirSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join, resolve } from "node:path"

const out = resolve(process.argv[2] ?? process.env.FAST_CHECKS_OUT ?? "rfd-shots")
mkdirSync(out, { recursive: true })
const app = resolve(new URL("..", import.meta.url).pathname)
// webviews/'s Playwright, loaded from the working directory: the app pins no browser tooling.
type Page = {
  goto(url: string): Promise<unknown>
  click(sel: string): Promise<void>
  hover(sel: string): Promise<void>
  fill(sel: string, text: string): Promise<void>
  waitForSelector(sel: string, opts?: { timeout?: number }): Promise<unknown>
  waitForTimeout(ms: number): Promise<void>
  textContent(sel: string, opts?: { timeout?: number }): Promise<string | null>
  addStyleTag(opts: { content: string }): Promise<unknown>
  screenshot(opts: { path: string }): Promise<unknown>
  on(event: string, fn: (e: { type(): string; text(): string; message: string }) => void): void
  close(): Promise<void>
  keyboard: { press(key: string): Promise<void>; type(text: string): Promise<void> }
}
type Browser = { newPage(opts: object): Promise<Page>; close(): Promise<void> }
const { chromium } = createRequire(join(process.cwd(), "package.json"))("playwright") as { chromium: { launch(): Promise<Browser> } }

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const path = decodeURIComponent(new URL(req.url).pathname)
    const file = Bun.file(join(app, path))
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 })
  },
})
const base = `http://127.0.0.1:${server.port}/preview/dist/index.html`

type Shot = { name: string; variant: string; rfd?: number; act?: (p: Page) => Promise<void> }
const shots: Shot[] = [
  { name: "a-doc", variant: "directory", rfd: 2 },
  { name: "b-table", variant: "index" },
  {
    name: "b-doc-comment",
    variant: "index",
    act: async (p) => {
      await p.click("li.row[data-rfd='2']")
      await p.waitForSelector(".thread")
      await p.click(".thread summary")
    },
  },
  { name: "c-doc", variant: "focus", rfd: 2 },
  {
    name: "a-search",
    variant: "directory",
    rfd: 2,
    act: async (p) => {
      await p.keyboard.press("Control+k")
      await p.keyboard.type("session row")
      await p.waitForSelector("#search-results li[data-rfd]")
    },
  },
  {
    name: "c-jump",
    variant: "focus",
    rfd: 2,
    act: async (p) => {
      await p.keyboard.press("Control+/")
      await p.waitForSelector("#jump-results li[data-rfd]")
    },
  },
  {
    name: "a-hover",
    variant: "directory",
    rfd: 3,
    act: async (p) => {
      await p.hover("#doc [data-rfd='1']")
      await p.waitForSelector("#hovercard:not([hidden])")
    },
  },
  {
    name: "a-new",
    variant: "directory",
    rfd: 2,
    act: async (p) => {
      await p.click("#new")
      await p.fill("#new-title", "A reader for RFDs")
    },
  },
]

const browser = await chromium.launch()
const rows: string[] = []
for (const scheme of ["light", "dark"] as const) {
  const page = await browser.newPage({ viewport: { width: 1360, height: 860 }, colorScheme: scheme, deviceScaleFactor: 1 })
  page.on("console", (m) => m.type() !== "log" && console.log(`page ${m.type()}: ${m.text()}`))
  page.on("pageerror", (e) => console.log(`page error: ${e.message}`))
  // cmux sets these from the theme; the preview mimics a light and a dark theme.
  const theme =
    scheme === "dark"
      ? "--cmux-text:#ececec;--cmux-text-secondary:#9a9a9f;--cmux-accent:#4c9bff;--cmux-separator:rgba(255,255,255,.12);--cmux-surface-background:#1c1c1e"
      : "--cmux-text:#1d1d1f;--cmux-text-secondary:#6e6e73;--cmux-accent:#0a6cff;--cmux-separator:rgba(0,0,0,.1);--cmux-surface-background:#ffffff"
  for (const s of shots) {
    const url = `${base}?variant=${s.variant}${s.rfd ? `&rfd=${s.rfd}` : ""}&commentDelay=50`
    await page.goto(url)
    await page.addStyleTag({ content: `:root{${theme}}` })
    await page.waitForSelector(s.rfd ? ".dochead" : "li.row")
    if (s.rfd) await page.waitForSelector("#comment-count:not(:empty)", { timeout: 5000 }).catch(() => console.log(`${s.name}: no comment count`))
    console.log(`${s.name}: status ${await page.textContent("#status", { timeout: 1000 }).catch(() => "-")} · count ${await page.textContent("#comment-count", { timeout: 1000 }).catch(() => "-")}`)
    if (s.act) await s.act(page).catch((e) => console.log(`${s.name}: step failed: ${String(e).split("\n")[0]}`))
    await page.waitForTimeout(350)
    const file = `${s.name}-${scheme}.png`
    await page.screenshot({ path: join(out, file) })
    rows.push(file)
    console.log(`shot ${file}`)
  }
  await page.close()
}
await browser.close()
server.stop()

writeFileSync(
  join(out, "gallery.html"),
  `<!doctype html><meta charset=utf-8><title>RFD reader variants</title><style>body{font:14px system-ui;margin:24px}figure{margin:0 0 28px}img{width:100%;max-width:1360px;border:1px solid #ccc;border-radius:8px}</style><h1>RFD reader: A directory, B index, C focus</h1>${rows.map((f) => `<figure><figcaption>${f}</figcaption><img src="${f}"></figure>`).join("")}`,
)
console.log(`${rows.length} shots in ${out}`)
