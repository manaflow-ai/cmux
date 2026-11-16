// local/reader-mode (examples/extensions/reader-mode) in the fake host, packed from src/main.ts:
// its one command runs the page script through browserPage.eval (`browser.page.eval`) and says so
// in a toast when there is nothing to read. The page script itself is tested against a DOM in
// examples/extensions/reader-mode/test/page.test.ts.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../../examples/extensions/reader-mode")
let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

function host() {
  const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
  const h = new FakeHost(built, { app: { id: manifest.id, version: "1.0.0" }, settings: {}, apiVersion: "1.0.0" })
  h.handlers["toast.show"] = () => ({ ok: true, body: { value: null } })
  return h
}

async function toggle(h: FakeHost) {
  h.runCommand("toggle", {}, 7)
  for (let i = 0; i < 50 && !h.commandResults.has(7); i++) await Bun.sleep(1)
  return h.commandResults.get(7)
}

describe("local/reader-mode", () => {
  test("the toggle runs the page script in the focused tab and answers what it did", async () => {
    const h = host()
    h.handlers["browser.page.eval"] = () => ({ ok: true, body: { value: { tab: "tab_1", value: { reader: true, title: "A story", words: 900, minutes: 4 } } } })
    const result = await toggle(h)
    expect(result).toEqual({ ok: true, body: { value: { reader: true, title: "A story", words: 900, minutes: 4 } } })
    const call = h.calls.find((c) => c.name === "browser.page.eval")!
    expect(Object.keys(call.params)).toEqual(["script"])
    expect(call.params.script).toContain("cmux-reader-mode")
    expect(call.params.script.length).toBeLessThan(60_000)
    expect(h.calls.some((c) => c.name === "toast.show")).toBe(false)
  })

  test("a page with no article says so in a toast", async () => {
    const h = host()
    h.handlers["browser.page.eval"] = () => ({ ok: true, body: { value: { tab: "tab_1", value: { reader: false, reason: "no_article" } } } })
    expect((await toggle(h))?.body.value).toEqual({ reader: false, reason: "no_article" })
    expect(h.calls.find((c) => c.name === "toast.show")?.params.title).toBe("No article to read on this page")
  })

  test("no browser tab focused is a toast, not an error", async () => {
    const h = host()
    h.handlers["browser.page.eval"] = () => ({ ok: false, body: { code: "not_found", message: "No focused browser surface", retryable: false } })
    expect((await toggle(h))?.body.value).toEqual({ reader: false, reason: "no_browser" })
    expect(h.calls.find((c) => c.name === "toast.show")?.params.title).toBe("Reader mode works in a browser tab")
  })
})

describe("local/reader-mode page key", () => {
  test("a page key's {tab} names the tab the script runs in", async () => {
    const h = host()
    h.handlers["browser.page.eval"] = () => ({ ok: true, body: { value: { tab: "tab_9", value: { reader: false } } } })
    h.runCommand("toggle", { tab: "tab_9" }, 8)
    for (let i = 0; i < 50 && !h.commandResults.has(8); i++) await Bun.sleep(1)
    expect(h.commandResults.get(8)?.body.value).toEqual({ reader: false })
    expect(h.calls.find((c) => c.name === "browser.page.eval")?.params.tab).toBe("tab_9")
  })
})

// The capture tour (scripts/cmux-next/media/tours/reader-mode.json) loads this packed copy on a Mac
// with no bun; it must be what the source packs to. Refresh it with
// `bun cmux-tui/crates/cmux-app-host/tools/pack.ts examples/extensions/reader-mode` and copy dist/main.js.
test("the capture tour's packed copy is current", () => {
  const fixture = join(import.meta.dir, "../../../../../examples/extensions/reader-mode/test/packed/main.js")
  // bun's `// path/to/module.js` lines depend on the folder it packs from; the code does not.
  const code = (text: string) => text.replace(/^\s*\/\/ \S+\.(?:js|ts)$/gm, "")
  expect(code(readFileSync(fixture, "utf8"))).toBe(code(built))
})
