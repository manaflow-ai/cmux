import { describe, expect, test } from "bun:test"
import type { HostToPane, PaneToHost } from "../src/interfaces/web-bridge.ts"
import type { DiffMountOptions, DocMountOptions, EditorAdapter } from "../src/shared/adapter.ts"
import { createBridge, hostTransport } from "../src/shared/bridge.ts"
import { startEditor } from "../src/shared/controller.ts"
import { FALLBACK_THEME } from "../src/shared/theme.ts"
import { FakeElement, fakeDocument } from "./fake-dom.ts"

const rev = (n: number) => ({ counter: n, hash: `h${n}` })
const info = (over: Record<string, unknown> = {}) => ({ doc: "doc_1", uri: "file://m/a.ts", name: "a.ts", type: { uti: "public.source-code", language: "typescript" }, encoding: "utf-8", lineEnding: "lf", revision: rev(1), dirty: false, readOnly: false, conflict: null, ...over })

/** An adapter that records calls and lets the test type and press Cmd-S. */
function fakeAdapter() {
  const calls: string[] = []
  let doc: DocMountOptions | null = null
  let diff: DiffMountOptions | null = null
  let text = ""
  const adapter: EditorAdapter = {
    name: "Fake",
    capabilities: ["diff", "readOnly"],
    mountDoc: (_el, o) => {
      doc = o
      text = o.text
      calls.push(`mountDoc:${o.language}:${o.readOnly}`)
    },
    setView: (t) => {
      text = t
      calls.push(`setView:${t}`)
    },
    setReadOnly: (ro) => calls.push(`setReadOnly:${ro}`),
    setLanguage: (l) => calls.push(`setLanguage:${l}`),
    setAppearance: () => calls.push("setAppearance"),
    mountDiff: (_el, o) => {
      diff = o
      calls.push(`mountDiff:${o.layout}`)
    },
    setDiffLayout: (l) => calls.push(`setDiffLayout:${l}`),
    focus: () => calls.push("focus"),
    destroy: () => calls.push("destroy")
  }
  return {
    adapter,
    calls,
    type: (t: string) => {
      text = t
      doc!.onChange(t)
    },
    save: () => doc!.onSave(),
    text: () => text,
    diff: () => diff
  }
}

/** A fake host: records page messages and answers calls from a handler table. */
function setup(props: Record<string, unknown>, ops: Record<string, (p: any) => unknown>, settings: Record<string, unknown> = {}) {
  const sent: PaneToHost[] = []
  const subs = new Map<string, number>()
  const doc = fakeDocument()
  const root = new FakeElement("div")
  const ed = fakeAdapter()
  const bridge = createBridge({
    post: (m) => {
      sent.push(m)
      if (m.kind === "subscribe") subs.set(m.stream, m.id)
      if (m.kind === "call") {
        const h = ops[m.op]
        queueMicrotask(() => {
          if (!h) return bridge.receive({ v: 1, kind: "result", id: m.id, ok: false, error: { code: "operation.unsupported", message: m.op } })
          try {
            bridge.receive({ v: 1, kind: "result", id: m.id, ok: true, value: h(m.params) })
          } catch (e) {
            const err = e as { code: string; message: string; details?: unknown }
            bridge.receive({ v: 1, kind: "result", id: m.id, ok: false, error: { code: err.code, message: err.message, details: err.details } })
          }
        })
      }
    }
  })
  const controller = startEditor(ed.adapter, bridge, root as unknown as HTMLElement, doc as unknown as Document)
  const receive = (m: Omit<HostToPane, "v">) => bridge.receive({ v: 1, ...m } as HostToPane)
  receive({ kind: "init", app: { id: "cmux/codemirror", version: "0.1.0" }, pane: "p1", locale: "en", theme: FALLBACK_THEME, settings, props, embedded: false, reduceMotion: false } as never)
  const settle = async () => {
    for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 0))
  }
  const calls = (op: string) => sent.filter((m): m is Extract<PaneToHost, { kind: "call" }> => m.kind === "call" && m.op === op)
  const emitted = () => sent.filter((m): m is Extract<PaneToHost, { kind: "emit" }> => m.kind === "emit").map((m) => m.event)
  const event = (stream: string, payload: unknown) => receive({ kind: "event", id: subs.get(stream)!, payload } as never)
  return { sent, ed, root, doc, controller, settle, calls, emitted, event, receive }
}

describe("editor controller over the bridge", () => {
  test("init opens the document, mounts the editor and announces ready", async () => {
    const h = setup({ doc: "doc_1" }, { "document.open": () => ({ info: info(), text: "let a = 1\n" }) })
    await h.settle()
    expect(h.calls("document.open")[0]!.params).toEqual({ doc: "doc_1" })
    expect(h.ed.calls[0]).toBe("mountDoc:typescript:false")
    expect(h.emitted()[0]).toEqual({ type: "ready", capabilities: ["diff", "readOnly"] })
    expect(h.sent.filter((m) => m.kind === "subscribe").map((m) => (m as { stream: string }).stream)).toEqual(["document.changed", "document.conflict"])
    expect(h.root.visibleText()).toContain("a.ts")
    expect(h.root.visibleText()).toContain("TypeScript")
  })

  test("typing sends document.edit; Cmd-S saves; the status line follows", async () => {
    let r = 1
    const h = setup({ doc: "doc_1" }, {
      "document.open": () => ({ info: info(), text: "abc" }),
      "document.edit": () => ({ revision: rev(++r), dirty: true }),
      "document.save": (p) => ({ revision: p.revision, dirty: false })
    })
    await h.settle()
    h.ed.type("abcd")
    expect(h.root.visibleText()).toContain("Edited")
    await h.settle()
    expect(h.calls("document.edit")[0]!.params).toEqual({ doc: "doc_1", base_revision: rev(1), edits: [{ from: 3, to: 3, text: "d" }] })
    h.ed.save()
    await h.settle()
    expect(h.calls("document.save")[0]!.params).toEqual({ doc: "doc_1", revision: rev(2) })
    expect(h.root.visibleText()).toContain("Saved")
    expect(h.emitted().filter((e) => e.type === "stateChanged").map((e) => e.state)).toEqual(["clean", "dirty", "saving", "clean"])
  })

  test("a host Save command runs in the pane and reports done", async () => {
    const h = setup({ doc: "doc_1" }, { "document.open": () => ({ info: info({ dirty: true }), text: "x" }), "document.save": () => ({ revision: rev(2), dirty: false }) })
    await h.settle()
    h.receive({ kind: "command", id: 77, command: "save", args: {} } as never)
    await h.settle()
    expect(h.sent.find((m) => m.kind === "commandDone")).toEqual({ v: 1, kind: "commandDone", id: 77, ok: true, value: { phase: "saving" } })
    expect(h.calls("document.save")).toHaveLength(1)
    h.receive({ kind: "command", id: 78, command: "nope", args: {} } as never)
    await h.settle()
    expect(h.sent.find((m) => m.kind === "commandDone" && m.id === 78)).toMatchObject({ ok: false, error: { code: "command.unknown" } })
  })

  test("an external change on a clean buffer reloads; a conflict shows the banner and Keep Mine overwrites", async () => {
    const h = setup({ doc: "doc_1" }, {
      "document.open": () => ({ info: info(), text: "abc" }),
      "document.save": (p) => ({ revision: rev(5), dirty: false, overwrite: p.overwrite_disk })
    })
    await h.settle()
    h.event("document.changed", { doc: "doc_1", base_revision: rev(1), revision: rev(2), edits: [{ from: 0, to: 1, text: "A" }], dirty: false, origin: "disk" })
    expect(h.ed.text()).toBe("Abc")
    expect(h.root.visibleText()).toContain("Reloaded from disk")
    h.event("document.conflict", { doc: "doc_1", disk_revision: rev(3), buffer_revision: rev(2) })
    expect(h.root.visibleText()).toContain("This file changed on disk while you were editing.")
    h.root.find((e) => e.tag === "button" && e.textContent === "Keep Mine")!.click()
    await h.settle()
    expect(h.calls("document.save").at(-1)!.params).toEqual({ doc: "doc_1", revision: rev(2), overwrite_disk: true })
    expect(h.root.visibleText()).not.toContain("This file changed on disk")
  })

  test("Compare asks the shell for a documents diff", async () => {
    const h = setup({ doc: "doc_1" }, { "document.open": () => ({ info: info({ dirty: true, conflict: { diskRevision: rev(3), bufferRevision: rev(2) } }), text: "abc" }), "ui.open": () => null })
    await h.settle()
    h.root.find((e) => e.tag === "button" && e.textContent === "Compare")!.click()
    await h.settle()
    expect(h.calls("ui.open")[0]!.params).toMatchObject({ interface: "cmux.diff.renderer/1", props: { input: { kind: "documents", base: { doc: "doc_1", revision: rev(3) }, head: { revision: rev(2) } } } })
    expect(h.emitted().find((e) => e.type === "openDiff")).toBeTruthy()
  })

  test("read-only from the owner or the prop", async () => {
    const h = setup({ doc: "doc_1", readOnly: true }, { "document.open": () => ({ info: info(), text: "abc" }) })
    await h.settle()
    expect(h.ed.calls[0]).toBe("mountDoc:typescript:true")
    h.ed.type("abcX")
    expect(h.ed.text()).toBe("abc")
    expect(h.calls("document.edit")).toHaveLength(0)
    h.receive({ kind: "props", props: { doc: "doc_1", readOnly: false } } as never)
    expect(h.ed.calls).toContain("setReadOnly:false")
  })

  test("diff mode reads both sides from the diff resource and follows layout props", async () => {
    const sides: Record<string, string> = { base: "a\nb\n", head: "a\nc\n" }
    const diffProps = (layout: string) => ({ readOnly: true, chrome: "none", diff: { original: { diff: "diff_1", path: "x.py", side: "base" }, modified: { diff: "diff_1", path: "x.py", side: "head" }, layout, path: "x.py" } })
    const h = setup(diffProps("sideBySide"), { "diff.file.read": (p) => ({ text: sides[p.side] }) })
    await h.settle()
    expect(h.calls("diff.file.read").map((c) => c.params)).toEqual([{ diff: "diff_1", path: "x.py", side: "base" }, { diff: "diff_1", path: "x.py", side: "head" }])
    expect(h.ed.diff()).toMatchObject({ original: "a\nb\n", modified: "a\nc\n", layout: "sideBySide", language: "python" })
    h.receive({ kind: "props", props: diffProps("inline") } as never)
    expect(h.ed.calls.at(-1)).toBe("setDiffLayout:inline")
  })

  test("a missing document op says which op is missing", async () => {
    const h = setup({ doc: "doc_1" }, {})
    await h.settle()
    expect(h.root.visibleText()).toContain("document.open is not available yet.")
  })

  test("variants: status line, header, bare", async () => {
    for (const [variant, header, status] of [["statusLine", false, true], ["header", true, false], ["bare", false, false]] as const) {
      const h = setup({ doc: "doc_1" }, { "document.open": () => ({ info: info({ dirty: true }), text: "x" }) }, { variant })
      await h.settle()
      expect([variant, !h.root.children[0]!.hidden, !h.root.children[3]!.hidden]).toEqual([variant, header, status])
    }
  })

  test("Japanese strings when the host locale is ja", async () => {
    const sent: PaneToHost[] = []
    const root = new FakeElement("div")
    const bridge = createBridge({ post: (m) => sent.push(m) })
    startEditor(fakeAdapter().adapter, bridge, root as unknown as HTMLElement, fakeDocument() as unknown as Document)
    bridge.receive({ v: 1, kind: "init", app: { id: "x", version: "1" }, pane: "p", locale: "ja-JP", theme: FALLBACK_THEME, settings: {}, props: {}, embedded: false, reduceMotion: false })
    expect(root.visibleText()).toContain("ドキュメントがありません")
  })
})

describe("bridge", () => {
  test("calls resolve and reject with code and details; unknown ids are ignored", async () => {
    const sent: PaneToHost[] = []
    const b = createBridge({ post: (m) => sent.push(m) })
    const ok = b.call("a.b", { x: 1 })
    const bad = b.call("c.d")
    expect(sent.map((m) => (m as { id: number }).id)).toEqual([1, 2])
    b.receive(JSON.stringify({ v: 1, kind: "result", id: 1, ok: true, value: 5 }))
    b.receive({ v: 1, kind: "result", id: 2, ok: false, error: { code: "x.y", message: "m", details: { k: 1 } } })
    b.receive({ v: 1, kind: "result", id: 99, ok: true, value: 0 })
    expect(await ok).toBe(5)
    await expect(bad).rejects.toMatchObject({ code: "x.y", details: { k: 1 } })
  })

  test("subscriptions deliver events until unsubscribed; messages without v:1 are dropped", () => {
    const sent: PaneToHost[] = []
    const b = createBridge({ post: (m) => sent.push(m) })
    const got: unknown[] = []
    const off = b.on("s.changed", { a: 1 }, (p) => got.push(p))
    b.receive({ v: 1, kind: "event", id: 1, payload: "one" })
    b.receive({ kind: "event", id: 1, payload: "dropped" } as never)
    off()
    off()
    b.receive({ v: 1, kind: "event", id: 1, payload: "two" })
    expect(got).toEqual(["one"])
    expect(sent.filter((m) => m.kind === "unsubscribe")).toHaveLength(1)
  })

  test("the host transport is window.webkit.messageHandlers.cmux, posting JSON", () => {
    const posted: unknown[] = []
    expect(hostTransport({})).toBeNull()
    hostTransport({ webkit: { messageHandlers: { cmux: { postMessage: (m: unknown) => posted.push(m) } } } })!.post({ v: 1, kind: "log", level: "info", message: "hi" })
    expect(posted).toEqual(['{"v":1,"kind":"log","level":"info","message":"hi"}'])
  })
})
