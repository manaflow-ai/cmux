// page.* and agent.ask: each wrapper is one cmux.call with the op's own name and params, and the
// gesture a command passes reaches the host. Runs an extension built on this package in the fake host.
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FakeHost, pack } from "../src/testing.ts"

const sdk = join(import.meta.dir, "../src/index.ts")
const dir = mkdtempSync(join(tmpdir(), "cmux-sdk-page-"))
let built = ""

beforeAll(async () => {
  mkdirSync(join(dir, "src"))
  writeFileSync(
    join(dir, "src/main.ts"),
    `import { agent, command, page } from "cmux-extension-sdk"
export const run = command(async (_args: unknown, ctx) => {
  const read = await page.read()
  const before = await page.style.get(read.origin)
  const set = await page.style.set({ origin: read.origin, hide: ["#ad"], unstick: [] })
  const js = await page.javascript.get({ origin: read.origin })
  const flipped = await page.javascript.set({ origin: read.origin, allowed: !js.allowed }, { gesture: ctx.gesture })
  const answer = await agent.ask({ prompt: "hi", model: "fast" }, { gesture: ctx.gesture })
  return { read, before, set, js, flipped, answer }
})
`
  )
  built = await pack(dir, { sdk })
})
afterAll(() => rmSync(dir, { recursive: true, force: true }))

const ok = (value: unknown) => ({ ok: true, body: { value } })

describe("page and agent wrappers", () => {
  test("call the ops by name with their params, and pass the gesture through", async () => {
    const h = new FakeHost(built, { app: { id: "local/sdk-test", version: "1.0.0" }, apiVersion: "1.0.0" })
    const read = { tab: "t1", url: "https://a.test/x", origin: "https://a.test", title: "A", candidates: [], truncated: false }
    h.handlers = {
      "page.read": () => ok(read),
      "page.style.get": () => ok(null),
      "page.style.set": (p) => ok({ origin: p.origin, rules: p.hide.length + p.unstick.length }),
      "page.javascript.get": (p) => ok({ origin: p.origin, allowed: true }),
      "page.javascript.set": (p) => ok({ origin: p.origin, allowed: p.allowed }),
      "agent.ask": () => ok({ text: "hello", ms: 12 })
    }
    h.runCommand("run", {}, 1, { gesture: "g-1" })
    await h.settle(20)
    expect(h.commandResults.get(1)).toEqual({
      ok: true,
      body: {
        value: {
          read,
          before: null,
          set: { origin: "https://a.test", rules: 1 },
          js: { origin: "https://a.test", allowed: true },
          flipped: { origin: "https://a.test", allowed: false },
          answer: { text: "hello", ms: 12 }
        }
      }
    })
    expect(h.calls.map((c) => [c.name, c.params, c.options.gesture ?? null])).toEqual([
      ["page.read", {}, null],
      ["page.style.get", { origin: "https://a.test" }, null],
      ["page.style.set", { origin: "https://a.test", hide: ["#ad"], unstick: [] }, null],
      ["page.javascript.get", { origin: "https://a.test" }, null],
      ["page.javascript.set", { origin: "https://a.test", allowed: false }, "g-1"],
      ["agent.ask", { prompt: "hi", model: "fast" }, "g-1"]
    ])
  })

  test("an op's error reaches the caller as a CmuxError code", async () => {
    const h = new FakeHost(built, { app: { id: "local/sdk-test", version: "1.0.0" }, apiVersion: "1.0.0" })
    h.handlers["page.read"] = () => ({ ok: false, body: { code: "page.none", message: "No browser tab is open", retryable: false } })
    h.runCommand("run", {}, 2, { gesture: "g-2" })
    await h.settle(10)
    expect(h.commandResults.get(2)).toEqual({ ok: false, body: { code: "page.none", message: "No browser tab is open", details: null } })
  })
})
