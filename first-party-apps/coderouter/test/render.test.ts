// Headless render tests: the built dist/main.js in the reference FakeHost,
// fed the same fixtures the preview harness uses.
import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const root = join(import.meta.dir, "..")
const source = readFileSync(join(root, "dist/main.js"), "utf8")
const fixture = (name: string) => JSON.parse(readFileSync(join(root, "preview", `${name}.json`), "utf8")) as { ops: Record<string, unknown> }

function host(fixtureName: string, settings: Record<string, unknown> = {}, extra: Record<string, unknown> = {}) {
  const h = new FakeHost(source, { app: { id: "cmux/coderouter", version: "0.1.0" }, apiVersion: "1.0.0", settings })
  const ops = { ...fixture(fixtureName).ops, ...extra }
  const counters = new Map<string, number>()
  for (const [name, spec] of Object.entries(ops)) {
    h.handlers[name] = () => {
      const s = spec as Record<string, unknown> | null
      if (s && typeof s === "object" && "$error" in s) return { ok: false, body: s.$error }
      if (s && typeof s === "object" && "$sequence" in s) {
        const list = s.$sequence as unknown[]
        const i = counters.get(name) ?? 0
        counters.set(name, i + 1)
        return { ok: true, body: { value: list[Math.min(i, list.length - 1)] } }
      }
      return { ok: true, body: { value: spec } }
    }
  }
  return h
}

/** Nodes reachable from the root (the reference host keeps removed subtrees in its map). */
function live(h: FakeHost, m: string) {
  const { root, nodes } = h.tree(m)
  const out: Array<[string, { type: string; props: Record<string, unknown> }]> = []
  const walk = (id: string) => {
    const n = nodes.get(id)
    if (!n) return
    out.push([id, n])
    n.children.forEach(walk)
  }
  walk(root)
  return out
}
const texts = (h: FakeHost, m: string) => live(h, m).flatMap(([, n]) => [n.props.title, n.props.text, n.props.subtitle, n.props.message, n.props.badge].filter((v) => typeof v === "string")) as string[]
const missing = (all: string[], wanted: string[]) => wanted.filter((w) => !all.includes(w))
const node = (h: FakeHost, m: string, label: string) => live(h, m).find(([, n]) => n.props.title === label || n.props.text === label)?.[0]
const tap = async (h: FakeHost, m: string, label: string) => {
  const id = node(h, m, label)
  if (!id) throw new Error(`no node "${label}" in ${JSON.stringify(texts(h, m))}`)
  h.dispatch(m, id, "tap")
  await h.settle(10)
}

describe("variants", () => {
  test("checklist: setup checklist in the sidebar section, current step expanded", async () => {
    const h = host("onboarding", { variant: "checklist" })
    expect(h.mount("s", "renderSection")).toBe("")
    await h.settle(10)
    const all = texts(h, "s")
    expect(missing(all, ["Set up CodeRouter", "See what you have", "Connect accounts", "Share with your team", "Use CodeRouter", "Send a test", "5 left", "Northwind Labs"])).toEqual([])
    expect(all).toContain("ChatGPT / Codex")
    await tap(h, "s", "Done")
    expect(texts(h, "s")).toContain("4 left")
    expect(h.calls.find((c) => c.name === "app.storage.set")?.params.key).toBe("onboarding")
  })

  test("wizard: Continue walks the steps, Connect asks the host, a passing test shows ready", async () => {
    const h = host("onboarding", { variant: "wizard" })
    expect(h.mount("p", "renderOnboarding")).toBe("")
    await h.settle(10)
    expect(missing(texts(h, "p"), ["See what you have", "Step 1 of 5", "ChatGPT / Codex", "Signed in", "Key found", "Expired"])).toEqual([])
    await tap(h, "p", "Continue")
    expect(texts(h, "p")).toContain("Step 2 of 5")
    await tap(h, "p", "Connect")
    const connect = h.calls.find((c) => c.name === "coderouter.accounts.connect")!
    expect(connect.params).toEqual({ provider: "codex" })
    for (const step of ["Step 3 of 5", "Step 4 of 5", "Step 5 of 5"]) {
      await tap(h, "p", "Continue")
      expect(texts(h, "p")).toContain(step)
    }
    await tap(h, "p", "Run Test")
    // A passing test proves the last step: the wizard lands on the ready screen with the result.
    expect(missing(texts(h, "p"), ["CodeRouter is ready", "gpt-5.5-codex in 412 ms"])).toEqual([])
  })

  test("tabs: dashboard opens on Setup while setup is pending, tabs switch sections", async () => {
    const h = host("onboarding-mid", { variant: "tabs" })
    expect(h.mount("d", "renderDashboard")).toBe("")
    await h.settle(10)
    expect(missing(texts(h, "d"), ["Overview", "Setup", "1. See what you have", "3. Share with your team"])).toEqual([])
    await tap(h, "d", "Usage")
    expect(missing(texts(h, "d"), ["$41.37", "a…@e… (Codex)"])).toEqual([])
    await tap(h, "d", "Routing")
    expect(texts(h, "d")).toContain("CodeRouter tries these in order. Drag to change it.")
  })

  test("sections dashboard shows every section", async () => {
    const h = host("dashboard", { variant: "wizard" })
    expect(h.mount("d", "renderDashboard")).toBe("")
    await h.settle(10)
    expect(missing(texts(h, "d"), ["Northwind Labs", "Healthy", "Accounts", "Failover order", "Usage", "API keys", "Test request", "o…@e…", "ci runner", "Shared", "Private"])).toEqual([])
  })

  test("status item: health dot and today's usage", async () => {
    const h = host("dashboard")
    expect(h.mount("t", "renderStatus")).toBe("")
    await h.settle(10)
    expect(texts(h, "t")).toContain("1.8M tok · $6.42")
    expect(h.calls.map((c) => c.name)).not.toContain("coderouter.accounts.list")
  })
})

describe("secrets never enter the app", () => {
  test("create key: the host presents the value; the app only passes the handle", async () => {
    const h = host("dashboard", { variant: "wizard" })
    h.mount("d", "renderDashboard")
    await h.settle(10)
    const field = live(h, "d").find(([, n]) => n.type === "TextField")![0]
    h.dispatch("d", field, "submit", { text: "editor" })
    await h.settle(10)
    expect(h.calls.find((c) => c.name === "coderouter.keys.create")!.params).toEqual({ label: "editor", present: "sheet" })
    expect(texts(h, "d")).toContain("editor created (crk_Q3vT…)")
    await tap(h, "d", "Copy")
    await tap(h, "d", "Show")
    expect(h.calls.find((c) => c.name === "clipboard.writeSecret")!.params).toEqual({ handle: "handle_9f2c" })
    expect(h.calls.find((c) => c.name === "ui.secret.reveal")!.params).toEqual({ handle: "handle_9f2c" })
    // No call carries anything shaped like a key or token.
    expect(JSON.stringify(h.calls.map((c) => c.params))).not.toMatch(/crk_[A-Za-z0-9]{8,}|sk-[A-Za-z0-9]|token|secret|password/i)
  })

  test("connect falls back to the existing accounts.connect action when the op is missing", async () => {
    const h = host("onboarding", { variant: "wizard" }, {})
    delete h.handlers["coderouter.accounts.connect"]
    h.mount("p", "renderOnboarding")
    await h.settle(10)
    await tap(h, "p", "Continue")
    await tap(h, "p", "Connect")
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "accounts.connect", args: { provider: "codex" } })
    expect(texts(h, "p")).toContain("Finish connecting ChatGPT / Codex in cmux.")
  })
})

describe("states", () => {
  test("today's platform: every proposed op is missing", async () => {
    const h = host("unsupported")
    h.mount("s", "renderSection")
    h.mount("t", "renderStatus")
    await h.settle(10)
    expect(missing(texts(h, "s"), ["Not available in this cmux build", "This build has no coderouter.status operation yet."])).toEqual([])
    expect(texts(h, "t")).toContain("")
  })

  test("unreachable: retry re-reads", async () => {
    const h = host("error", { variant: "wizard" })
    h.mount("d", "renderDashboard")
    await h.settle(10)
    expect(texts(h, "d")).toContain("Cannot reach CodeRouter")
    const before = h.calls.filter((c) => c.name === "coderouter.status").length
    await tap(h, "d", "Try Again")
    expect(h.calls.filter((c) => c.name === "coderouter.status").length).toBe(before + 1)
  })

  test("signed out: sign-in runs the existing action", async () => {
    const h = host("signedout", { variant: "checklist" })
    h.mount("s", "renderSection")
    await h.settle(10)
    await tap(h, "s", "Sign in to cmux")
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "palette.auth.signIn", args: {} })
  })

  test("empty personal scope: share step not needed, accounts empty state", async () => {
    const h = host("empty", { variant: "tabs" })
    h.mount("d", "renderDashboard")
    await h.settle(10)
    expect(missing(texts(h, "d"), ["Personal: not needed", "No sign-ins or keys on this Mac. You can paste a key in the next step."])).toEqual([])
  })

  test("Japanese", async () => {
    const h = host("onboarding", { variant: "checklist", language: "ja" })
    h.mount("s", "renderSection")
    await h.settle(10)
    expect(missing(texts(h, "s"), ["CodeRouter を設定", "アカウントを接続", "残り 5"])).toEqual([])
  })
})

describe("commands", () => {
  test("cycleVariant steps through the variants for this session", async () => {
    const h = host("dashboard")
    const run = async (name: string, args = {}) => {
      h.global.__cmuxAppRunCommand(name, JSON.stringify(args), 1)
      await h.settle(10)
      return h.commandResults.get(1)!
    }
    expect((await run("cycleVariant")).body.value).toEqual({ variant: "wizard" })
    expect((await run("cycleVariant")).body.value).toEqual({ variant: "tabs" })
    expect((await run("connectAccount")).body.value).toEqual({ provider: "openai", connected: true })
    expect((await run("runTest")).body.value.model).toBe("gpt-5.5-codex")
  })
})
