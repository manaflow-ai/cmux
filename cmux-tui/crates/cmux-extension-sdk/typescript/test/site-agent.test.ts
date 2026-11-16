// site.* and agent.ask: each wrapper is one cmux.call with the op's own name and params, and the
// gesture a command passes reaches the host. Runs an extension built on this package in the fake host.
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FakeHost, pack } from "../src/testing.ts"

const sdk = join(import.meta.dir, "../src/index.ts")
const dir = mkdtempSync(join(tmpdir(), "cmux-sdk-site-"))
let built = ""

beforeAll(async () => {
  mkdirSync(join(dir, "src"))
  writeFileSync(
    join(dir, "src/main.ts"),
    `import { agent, command, site } from "cmux-extension-sdk"
export const run = command(async (_args: unknown, ctx) => {
  const origin = "https://a.test"
  const before = await site.style.get(origin)
  const set = await site.style.set({ origin, hide: ["#ad"], unstick: [] })
  const js = await site.javascript.get({ origin })
  const flipped = await site.javascript.set({ origin, allowed: !js.allowed }, { gesture: ctx.gesture })
  const answer = await agent.ask({ prompt: "hi", model: "fast" }, { gesture: ctx.gesture })
  return { before, set, js, flipped, answer }
})
`
  )
  built = await pack(dir, { sdk })
})
afterAll(() => rmSync(dir, { recursive: true, force: true }))

const ok = (value: unknown) => ({ ok: true, body: { value } })
const init = { app: { id: "local/sdk-test", version: "1.0.0" }, apiVersion: "1.0.0" }

describe("site and agent wrappers", () => {
  test("call the ops by name with their params, and pass the gesture through", async () => {
    const h = new FakeHost(built, init)
    h.handlers = {
      "browser.site.style.get": () => ok(null),
      "browser.site.style.set": (p) => ok({ origin: p.origin, rules: p.hide.length + p.unstick.length }),
      "browser.site.javascript.get": (p) => ok({ origin: p.origin, allowed: true }),
      "browser.site.javascript.set": (p) => ok({ origin: p.origin, allowed: p.allowed }),
      "agent.ask": () => ok({ text: "hello", ms: 12 })
    }
    h.runCommand("run", {}, 1, { gesture: "g-1" })
    await h.settle(20)
    expect(h.commandResults.get(1)).toEqual({
      ok: true,
      body: {
        value: {
          before: null,
          set: { origin: "https://a.test", rules: 1 },
          js: { origin: "https://a.test", allowed: true },
          flipped: { origin: "https://a.test", allowed: false },
          answer: { text: "hello", ms: 12 }
        }
      }
    })
    expect(h.calls.map((c) => [c.name, c.params, c.options.gesture ?? null])).toEqual([
      ["browser.site.style.get", { origin: "https://a.test" }, null],
      ["browser.site.style.set", { origin: "https://a.test", hide: ["#ad"], unstick: [] }, null],
      ["browser.site.javascript.get", { origin: "https://a.test" }, null],
      ["browser.site.javascript.set", { origin: "https://a.test", allowed: false }, "g-1"],
      ["agent.ask", { prompt: "hi", model: "fast" }, "g-1"]
    ])
  })

  test("an op's error reaches the caller with its code", async () => {
    const h = new FakeHost(built, init)
    h.handlers["browser.site.style.get"] = () => ({ ok: false, body: { code: "validation.invalid", message: "bad origin", retryable: false } })
    h.runCommand("run", {}, 2, { gesture: "g-2" })
    await h.settle(10)
    expect(h.commandResults.get(2)).toEqual({ ok: false, body: { code: "validation.invalid", message: "bad origin", details: null } })
  })
})
