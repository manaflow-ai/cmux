import { describe, expect, test } from "bun:test"
import type { DocInfo, DocRevision } from "../src/interfaces/document.ts"
import { applyEdits, initialDocState, rebase, reduce, region, reopened, type DocEffect, type DocEvent, type DocState } from "../src/shared/doc-session.ts"

const rev = (n: number): DocRevision => ({ counter: n, hash: `h${n}` })
const info = (over: Partial<DocInfo> = {}): DocInfo => ({ doc: "doc_1", uri: "file://m/a.ts", name: "a.ts", type: { uti: "public.source-code", language: "typescript" }, encoding: "utf-8", lineEnding: "lf", revision: rev(1), dirty: false, readOnly: false, conflict: null, ...over })

function run(events: DocEvent[], start: DocState = initialDocState()) {
  let s = start
  const effects: DocEffect[] = []
  for (const e of events) {
    const r = reduce(s, e)
    s = r.state
    effects.push(...r.effects)
  }
  return { s, effects }
}

const opened = (text = "hello world", over: Partial<DocInfo> = {}) => run([{ type: "opened", info: info(over), text }]).s

describe("text helpers", () => {
  test("region is the single replacement between two texts", () => {
    expect(region("abc", "abc")).toBeNull()
    expect(region("hello world", "hello brave world")).toEqual({ from: 6, to: 6, text: "brave " })
    expect(region("aaa", "aa")).toEqual({ from: 2, to: 3, text: "" })
    expect(region("", "x")).toEqual({ from: 0, to: 0, text: "x" })
    for (const [a, b] of [["abcabc", "abXabc"], ["xx", "xxxx"], ["one\ntwo", "one\nthree\ntwo"]]) expect(applyEdits(a!, [region(a!, b!)!])).toBe(b!)
  })

  test("applyEdits applies in order and rejects ranges outside the text", () => {
    expect(applyEdits("abc", [{ from: 0, to: 1, text: "X" }, { from: 3, to: 3, text: "!" }])).toBe("Xbc!")
    expect(() => applyEdits("abc", [{ from: 2, to: 9, text: "" }])).toThrow()
  })

  test("rebase keeps both changes in different places", () => {
    expect(rebase("one two three", "ONE two three", "one two THREE")).toEqual({ text: "ONE two THREE", overlapped: false })
    expect(rebase("one two three", "one two THREE", "ONE two three")).toEqual({ text: "ONE two THREE", overlapped: false })
    expect(rebase("abc", "abc", "abXc").text).toBe("abXc")
    expect(rebase("abc", "aYbc", "abc").text).toBe("aYbc")
  })

  test("rebase of overlapping changes keeps the owner's text and the view's typing", () => {
    const r = rebase("hello world", "hello WORLD", "hello word")
    expect(r).toEqual({ text: "hello worWORLDd", overlapped: true })
    expect(rebase("hello world", "hello there world", "hello big world")).toEqual({ text: "hello there big world", overlapped: false })
  })
})

describe("document state machine", () => {
  test("open: clean, ready, view set", () => {
    const r = reduce(initialDocState(), { type: "opened", info: info(), text: "x" })
    expect(r.state).toMatchObject({ phase: "ready", dirty: false, confirmedText: "x", viewText: "x" })
    expect(r.effects).toEqual([{ type: "setView", text: "x", edits: [{ from: 0, to: 0, text: "x" }] }])
  })

  test("typing: one edit in flight, later typing waits, the ack sends the rest", () => {
    let { s, effects } = run([{ type: "viewChanged", text: "hello brave world" }], opened())
    expect(s.dirty).toBe(true)
    expect(effects).toEqual([{ type: "sendEdit", id: 1, base: rev(1), edits: [{ from: 6, to: 6, text: "brave " }] }])
    ;({ s, effects } = run([{ type: "viewChanged", text: "hello brave new world" }], s))
    expect(effects).toEqual([])
    ;({ s, effects } = run([{ type: "editAcked", id: 1, revision: rev(2), dirty: true }], s))
    expect(s.confirmedText).toBe("hello brave world")
    expect(effects).toEqual([{ type: "sendEdit", id: 2, base: rev(2), edits: [{ from: 12, to: 12, text: "new " }] }])
    ;({ s, effects } = run([{ type: "editAcked", id: 2, revision: rev(3), dirty: true }], s))
    expect(effects).toEqual([])
    expect(s).toMatchObject({ inflight: null, revision: rev(3), dirty: true })
  })

  test("save waits for the in-flight edit, then saves the confirmed revision", () => {
    let { s, effects } = run([{ type: "viewChanged", text: "hello!" }, { type: "saveRequested" }], opened("hello"))
    expect(effects.map((e) => e.type)).toEqual(["sendEdit"])
    expect(s.saveQueued).toBe(true)
    ;({ s, effects } = run([{ type: "editAcked", id: 1, revision: rev(2), dirty: true }], s))
    expect(effects).toEqual([{ type: "save", revision: rev(2), overwriteDisk: false }])
    expect(s.phase).toBe("saving")
    ;({ s } = run([{ type: "saved", revision: rev(2) }], s))
    expect(s).toMatchObject({ phase: "ready", dirty: false, notice: "saved" })
  })

  test("a clean save request saves at once; a save conflict enters the conflict state", () => {
    let { s, effects } = run([{ type: "saveRequested" }], opened("a", { dirty: true }))
    expect(effects).toEqual([{ type: "save", revision: rev(1), overwriteDisk: false }])
    ;({ s } = run([{ type: "saveFailed", code: "document.conflict", message: "disk moved", diskRevision: rev(5) }], s))
    expect(s.phase).toBe("conflict")
    expect(s.conflict).toEqual({ diskRevision: rev(5), bufferRevision: rev(1) })
  })

  test("stale base: resync, then the local change rebases onto the owner's text and is resent", () => {
    let { s, effects } = run([{ type: "viewChanged", text: "one two three!" }], opened("one two three"))
    ;({ s, effects } = run([{ type: "editFailed", id: 1, code: "document.revision_mismatch", message: "stale" }], s))
    expect(effects).toEqual([{ type: "resync" }])
    const r = reopened(s, info({ revision: rev(4), dirty: true }), "ONE two three")
    expect(r.state.viewText).toBe("ONE two three!")
    expect(r.effects).toEqual([
      { type: "setView", text: "ONE two three!", edits: [{ from: 0, to: 3, text: "ONE" }] },
      { type: "sendEdit", id: 2, base: rev(4), edits: [{ from: 13, to: 13, text: "!" }] }
    ])
  })

  test("remote edits from another view merge into the view; own echo acts as the ack", () => {
    let { s, effects } = run([{ type: "viewChanged", text: "abc!" }], opened("abc"))
    ;({ s, effects } = run([{ type: "remoteChanged", ownOrigin: "view:p1", event: { doc: "doc_1", base_revision: rev(1), revision: rev(2), edits: [{ from: 3, to: 4, text: "" }], dirty: true, origin: "view:p1" } }], s))
    expect(s).toMatchObject({ confirmedText: "abc!", inflight: null, revision: rev(2) })
    expect(effects).toEqual([])
    ;({ s, effects } = run([{ type: "remoteChanged", ownOrigin: "view:p1", event: { doc: "doc_1", base_revision: rev(2), revision: rev(3), edits: [{ from: 0, to: 0, text: ">" }], dirty: true, origin: "agent:a1" } }], s))
    expect(s.viewText).toBe(">abc!")
    expect(effects).toEqual([{ type: "setView", text: ">abc!", edits: [{ from: 0, to: 0, text: ">" }] }])
  })

  test("a disk change on a clean buffer reloads with a notice; a gap in revisions resyncs", () => {
    let { s, effects } = run([{ type: "remoteChanged", ownOrigin: "view:p1", event: { doc: "doc_1", base_revision: rev(1), revision: rev(2), edits: [{ from: 0, to: 1, text: "A" }], dirty: false, origin: "disk" } }], opened("abc"))
    expect(s).toMatchObject({ viewText: "Abc", notice: "reloaded", dirty: false })
    ;({ effects } = run([{ type: "remoteChanged", ownOrigin: "view:p1", event: { doc: "doc_1", base_revision: rev(7), revision: rev(8), edits: [], dirty: false, origin: "disk" } }], s))
    expect(effects).toEqual([{ type: "resync" }])
  })

  test("conflict: keep mine saves over the disk, use disk reverts", () => {
    const c = run([{ type: "conflict", diskRevision: rev(9), bufferRevision: rev(1) }], opened("x", { dirty: true })).s
    expect(c.phase).toBe("conflict")
    expect(run([{ type: "saveRequested" }], c).effects).toEqual([]) // no plain save while in conflict
    expect(run([{ type: "resolve", keep: "buffer" }], c).effects).toEqual([{ type: "save", revision: rev(1), overwriteDisk: true }])
    expect(run([{ type: "resolve", keep: "disk" }], c).effects).toEqual([{ type: "revert" }])
  })

  test("read-only (owner or prop) puts typed text back and never sends", () => {
    let { s, effects } = run([{ type: "viewChanged", text: "abX" }], opened("ab", { readOnly: true, readOnlyReason: "permissions" }))
    expect(effects).toEqual([{ type: "setView", text: "ab", edits: [{ from: 2, to: 3, text: "" }] }])
    expect(s.notice).toBe("readOnly")
    ;({ s, effects } = run([{ type: "setReadOnly", readOnly: true }, { type: "viewChanged", text: "abY" }, { type: "saveRequested" }], opened("ab")))
    expect(effects.map((e) => e.type)).toEqual(["setView"])
  })

  test("an owner read_only rejection reverts the view and turns read-only", () => {
    const { s, effects } = run([{ type: "viewChanged", text: "ab!" }, { type: "editFailed", id: 1, code: "document.read_only", message: "no" }], opened("ab"))
    expect(s).toMatchObject({ readOnly: true, viewText: "ab" })
    expect(effects.at(-1)).toEqual({ type: "setView", text: "ab", edits: [{ from: 2, to: 3, text: "" }] })
  })

  test("late acks for an old edit are ignored", () => {
    const s = opened("a")
    expect(run([{ type: "editAcked", id: 42, revision: rev(9), dirty: false }], s).s).toBe(s)
  })
})
