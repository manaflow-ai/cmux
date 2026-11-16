// JavaScript for this site in the fake host: the toggle reads the setting, sets the opposite with
// the command's gesture, and says the new state.
import { beforeAll, describe, expect, test } from "bun:test"
import { join } from "node:path"
import { FakeHost, pack } from "cmux-extension-sdk/testing"
import { hostOf, notice } from "../src/main.ts"

const ok = (value: unknown) => ({ ok: true, body: { value } })
let built = ""
beforeAll(async () => {
  built = await pack(join(import.meta.dir, ".."))
})

function host(allowed: boolean) {
  const h = new FakeHost(built, { app: { id: "local/showcase-site-js", version: "1.0.0" }, apiVersion: "1.0.0" })
  const state = { allowed }
  h.handlers = {
    "page.javascript.get": () => ok({ origin: "https://www.news.test", allowed: state.allowed }),
    "page.javascript.set": (p) => {
      state.allowed = p.allowed
      return ok({ origin: p.origin, allowed: p.allowed })
    },
    "toast.show": () => ok(null)
  }
  return { h, state }
}
const toasts = (h: FakeHost) => h.calls.filter((c) => c.name === "toast.show").map((c) => c.params)

describe("local/showcase-site-js", () => {
  test("turns JavaScript off with the gesture, then back on", async () => {
    const { h, state } = host(true)
    h.runCommand("toggle", {}, 1, { gesture: "g-1" })
    await h.settle(10)
    expect(h.commandResults.get(1)).toEqual({ ok: true, body: { value: { origin: "https://www.news.test", allowed: false } } })
    const set = h.calls.find((c) => c.name === "page.javascript.set")!
    expect([set.params, set.options.gesture]).toEqual([{ origin: "https://www.news.test", allowed: false }, "g-1"])
    expect(state.allowed).toBe(false)
    expect(toasts(h)).toEqual([{ title: "JavaScript off for www.news.test" }])

    h.runCommand("toggle", {}, 2, { gesture: "g-2" })
    await h.settle(10)
    expect(state.allowed).toBe(true)
    expect(toasts(h).at(-1)).toEqual({ title: "JavaScript on for www.news.test", tone: "success" })
  })

  test("no browser tab: says to open one and changes nothing", async () => {
    const { h } = host(true)
    h.handlers["page.javascript.get"] = () => ({ ok: false, body: { code: "page.none", message: "No browser tab is open", retryable: false } })
    h.runCommand("toggle", {}, 1, { gesture: "g-1" })
    await h.settle(10)
    expect(h.calls.some((c) => c.name === "page.javascript.set")).toBe(false)
    expect(toasts(h)).toEqual([{ title: "Open a web page first", tone: "warning" }])
  })

  test("the toast text", () => {
    expect(hostOf("http://a.test:8080")).toBe("a.test:8080")
    expect(notice("https://a.test", false)).toBe("JavaScript off for a.test")
  })
})
