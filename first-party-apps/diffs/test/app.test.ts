import { describe, expect, test } from "bun:test"
import { scanCalls } from "./l10n-scan.ts"
import { findText, fixture, makeHost, run, tap, texts, visible } from "./harness.ts"

const FOCUS_OPS = ["workspace.focus", "pane.focus", "tab.focus", "screen.focus", "terminal.input.focus", "browser.activate"]

describe("diff pane variants", () => {
  for (const variant of ["split", "stream", "review"]) {
    test(`${variant}: loads the working tree diff through git.status and git.diff`, async () => {
      const host = makeHost({ variant })
      expect(host.mount("m", "renderDiffPane")).toBe("")
      await host.settle(20)
      expect(host.calls.map((c) => c.name)).toEqual(["workspace.list", "git.status", "git.diff"])
      expect(host.calls[2]!.params).toMatchObject({ repo: "repo_orbit", include_patch: true })
      const all = texts(host, "m")
      expect(all).toContain("orbit · cache-evictions")
      expect(all).toContain("Built-in diff view")
      expect(all.some((s) => s.includes("clear(): void {"))).toBe(true)
      if (variant === "split") expect(all).toContain("lru.ts")
      expect(host.calls.filter((c) => FOCUS_OPS.includes(c.name))).toEqual([])
    })
  }

  test("split: selecting a file shows its diff", async () => {
    const host = makeHost({ variant: "split" })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    expect(texts(host, "m").some((s) => s.includes("metrics.count"))).toBe(false)
    await tap(host, "m", "routes.ts")
    expect(texts(host, "m").some((s) => s.includes("metrics.count"))).toBe(true)
  })

  test("side-by-side layout pairs old and new lines in two cells", async () => {
    const host = makeHost({ variant: "stream", layout: "sideBySide" })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    const all = texts(host, "m").map((s) => s.trim())
    expect(all).toContain("constructor(private readonly capacity: number) {}")
    expect(all.some((s) => s.startsWith("constructor(private readonly capacity: number, private"))).toBe(true)
    expect(all.some((s) => s.startsWith("- "))).toBe(false) // no inline markers in side-by-side cells
  })

  test("Stage sends diff.decide for one hunk; Discard needs a second tap", async () => {
    const host = makeHost({ variant: "split" })
    host.handlers["diff.decide"] = (p) => ({ ok: true, body: { value: { applied: p.decisions } } })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    await tap(host, "m", "Stage")
    let decide = host.calls.filter((c) => c.name === "diff.decide")
    expect(decide).toHaveLength(1)
    expect(decide[0]!.params).toMatchObject({ diff: "diff_worktree1", decisions: [{ path: "src/cache/lru.ts", decision: "accept" }] })
    expect(texts(host, "m")).toContain("Accepted")

    await tap(host, "m", "routes.ts")
    await tap(host, "m", "Discard")
    expect(host.calls.filter((c) => c.name === "diff.decide")).toHaveLength(1)
    expect(texts(host, "m")).toContain("Discard?")
    await tap(host, "m", "Discard?")
    decide = host.calls.filter((c) => c.name === "diff.decide")
    expect(decide).toHaveLength(2)
    expect(decide[1]!.params.decisions).toEqual([{ path: "src/server/routes.ts", decision: "reject" }])
  })

  test("a missing diff.decide keeps the decision local and says what is missing", async () => {
    const host = makeHost({ variant: "split" })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    await tap(host, "m", "Stage")
    expect(texts(host, "m")).toContain("diff.decide is not available yet.")
    expect(texts(host, "m")).toContain("Undo")
  })

  test("missing git ops show which op is missing", async () => {
    const host = makeHost({}, fixture("missing").ops)
    host.mount("m", "renderDiffPane")
    host.mount("s", "renderChanges")
    await host.settle(20)
    expect(texts(host, "m")).toContain("git.status is not available yet.")
    expect(texts(host, "s")).toContain("git.status is not available yet.")
  })

  test("review: a feed request loads its diff; comments and verdict go back as the answer", async () => {
    const host = makeHost({ variant: "review" })
    host.handlers["feed.answer"] = () => ({ ok: true, body: { value: { state: "answered" } } })
    host.handlers["diff.decide"] = (p) => ({ ok: true, body: { value: { applied: p.decisions } } })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    const r = await run(host, "reviewLatest")
    expect(r.ok).toBe(true)
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "feed.get")!.params).toMatchObject({ item: "fi_review42" })
    expect(host.calls.find((c) => c.name === "diff.get")!.params).toMatchObject({ diff: "diff_prop7" })
    const all = texts(host, "m")
    expect(all).toContain("Count cache evictions and add clear()")
    expect(all).toContain("Evictions are counted")
    expect(all).toContain("Accepted") // routes.ts was accepted before (owner decisions)

    await tap(host, "m", "+     this.entries.clear()")
    const field = visible(host, "m").find(([, n]) => n.type === "TextField")![0]
    host.dispatch("m", field, "submit", { text: "Also reset hit counters" })
    await host.settle(10)
    expect(texts(host, "m").some((s) => s.includes("Also reset hit counters"))).toBe(true)
    expect(host.calls.some((c) => c.name === "diff.comment.add")).toBe(false) // feed reviews carry comments in the answer

    await tap(host, "m", "Accept All")
    expect(host.calls.filter((c) => c.name === "diff.decide")).toHaveLength(1)
    await tap(host, "m", "Submit Review: Approve")
    const answer = host.calls.find((c) => c.name === "feed.answer")!
    expect(answer.params).toEqual({ item: "fi_review42", value: { verdict: "approve", notes: [{ path: "src/cache/lru.ts", line: 51, text: "Also reset hit counters" }] } })
    expect(texts(host, "m")).toContain("Review sent")
  })

  test("with an editor app and the Embed node, file bodies are embeds", async () => {
    const host = makeHost({ variant: "split", editorApp: "cmux/monaco" })
    host.eval(`globalThis.Embed = (p) => Text("embed:" + p.embed)`)
    host.handlers["ui.embed.create"] = () => ({ ok: true, body: { value: { embed: "emb_1", app: "cmux/monaco", capabilities: ["diff"] } } })
    host.handlers["ui.embed.update"] = () => ({ ok: true, body: { value: null } })
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    const create = host.calls.find((c) => c.name === "ui.embed.create")!
    expect(create.params).toMatchObject({
      interface: "cmux.editor/1",
      prefer: "cmux/monaco",
      props: { readOnly: true, diff: { original: { diff: "diff_worktree1", path: "src/cache/lru.ts", side: "base" }, modified: { side: "head" }, layout: "inline" } }
    })
    expect(texts(host, "m")).toContain("embed:emb_1")
    expect(texts(host, "m")).toContain("Shown with cmux/monaco")
    await run(host, "toggleLayout")
    await host.settle(10)
    expect(host.calls.find((c) => c.name === "ui.embed.update")!.params.props.diff.layout).toBe("sideBySide")
  })

  test("a failed embed falls back to the built-in diff", async () => {
    const host = makeHost({ variant: "split" })
    host.eval(`globalThis.Embed = (p) => Text("embed:" + p.embed)`)
    host.mount("m", "renderDiffPane")
    await host.settle(20)
    expect(texts(host, "m").some((s) => s.includes("clear(): void {"))).toBe(true)
  })
})

describe("Changes section", () => {
  test("rows per file, staged group first, tap opens the diff pane at that file", async () => {
    const host = makeHost()
    host.mount("s", "renderChanges")
    await host.settle(20)
    const all = texts(host, "s")
    expect(all).toEqual(expect.arrayContaining(["cache-evictions", "Staged", "Changes", "lru.ts", "routes.ts", "todo.txt"]))
    expect(all.indexOf("Staged")).toBeLessThan(all.indexOf("Changes"))
    await tap(host, "s", "routes.ts")
    await host.settle(10)
    expect(host.calls.find((c) => c.name === "app.pane.open")!.params).toMatchObject({ kind: "diff", input: { kind: "worktree", staged: false }, focus_path: "src/server/routes.ts" })
  })

  test("reloads on git.changed for its repository only", async () => {
    const host = makeHost()
    host.mount("s", "renderChanges")
    await host.settle(20)
    const before = host.calls.filter((c) => c.name === "git.status").length
    host.emit("git.changed", { repo: "repo_other" })
    await host.settle(10)
    expect(host.calls.filter((c) => c.name === "git.status").length).toBe(before)
    host.emit("git.changed", { repo: "repo_orbit" })
    await host.settle(10)
    expect(host.calls.filter((c) => c.name === "git.status").length).toBe(before + 1)
  })

  test("empty repository state", async () => {
    const host = makeHost({}, fixture("empty").ops)
    host.mount("s", "renderChanges")
    await host.settle(20)
    expect(texts(host, "s")).toContain("No changes")
  })
})

describe("commands", () => {
  test("openDiff needs repo, base and head", async () => {
    const host = makeHost()
    expect((await run(host, "openDiff", { repo: "repo_orbit" })).body.code).toBe("invalid_params")
    const ok = await run(host, "openDiff", { repo: "repo_orbit", base: "main", head: "HEAD" })
    expect(ok.body.value).toEqual({ opened: false, reason: "operation.unsupported" })
  })

  test("review needs a target; cycleVariant walks the variants", async () => {
    const host = makeHost()
    expect((await run(host, "review", {})).body.code).toBe("invalid_params")
    expect((await run(host, "cycleVariant")).body.value).toEqual({ variant: "stream", persisted: false })
    expect((await run(host, "cycleVariant")).body.value.variant).toBe("review")
  })
})

describe("localization", () => {
  test("every t() key has English and Japanese strings", async () => {
    const en = await Bun.file(new URL("../strings/en.json", import.meta.url)).json()
    const ja = await Bun.file(new URL("../strings/ja.json", import.meta.url)).json()
    const calls = scanCalls(new URL("../src", import.meta.url).pathname)
    for (const [key, english] of calls) {
      expect([key, en[key]]).toEqual([key, english])
      expect([key, typeof ja[key]]).toEqual([key, "string"])
    }
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
  })
})
