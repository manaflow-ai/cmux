import { describe, expect, test } from "bun:test"
import { parseLines } from "../src/markdown.ts"
import { applyOp, appendText, deriveTitle, fileNameOf, LIMITS, NoteError, parseDocument, previewOf, searchNotes, sortNotes, summaryOf, toMarkdown, toggleCheckLine, type Note, type NoteOp, type Stamp } from "../src/model.ts"
import { t, setLanguage, translatedKeys } from "../src/l10n.ts"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"

const deepFreeze = (v: unknown): void => {
  if (v && typeof v === "object" && !Object.isFrozen(v)) {
    Object.freeze(v)
    for (const x of Object.values(v)) deepFreeze(x)
  }
}
const ui: Stamp = { now: 1000, via: "ui" }
const at = (now: number, via: Stamp["via"] = "ui"): Stamp => ({ now, via })
const create = (notes: Note[], id: string, extra: Partial<Extract<NoteOp, { kind: "create" }>> = {}, now = 1000) => applyOp(notes, { kind: "create", id, ...extra }, at(now)).notes

describe("applyOp", () => {
  test("create, append, set title bump revision and updatedAt", () => {
    let notes = create([], "a", { body: "first" })
    expect(notes[0]!.revision).toBe(1)
    const r = applyOp(notes, { kind: "append", id: "a", text: "second\r\n" }, at(2000, "command"))
    expect(r.note!.body).toBe("first\nsecond")
    expect(r.note!.revision).toBe(2)
    expect(r.note!.updatedAt).toBe(2000)
    expect(r.note!.lastEdit).toEqual({ via: "command" })
    notes = applyOp(r.notes, { kind: "setTitle", id: "a", title: "  Plan\nB  " }, at(3000)).notes
    expect(notes[0]!.title).toBe("Plan B")
  })

  test("a no-op write changes nothing (no revision bump, no reorder)", () => {
    const notes = create([], "a", { body: "x", title: "T" })
    const r = applyOp(notes, { kind: "setTitle", id: "a", title: "T" }, at(5000))
    expect(r.changed).toBe(false)
    expect(r.note!.revision).toBe(1)
    expect(r.note!.updatedAt).toBe(1000)
  })

  test("pin and attach do not move the note in the recent order", () => {
    const notes = create([], "a", { body: "x" })
    const pinned = applyOp(notes, { kind: "setPinned", id: "a", pinned: true }, at(9000)).note!
    expect(pinned.revision).toBe(2)
    expect(pinned.updatedAt).toBe(1000)
  })

  test("at most one scratchpad per workspace: creating again returns the existing one", () => {
    const ws = { id: "workspace_1", name: "api" }
    const notes = create([], "pad", { workspace: ws, scratchpad: true })
    const again = applyOp(notes, { kind: "create", id: "other", workspace: ws, scratchpad: true }, ui)
    expect(again.changed).toBe(false)
    expect(again.note!.id).toBe("pad")
    expect(again.notes).toHaveLength(1)
  })

  test("detaching a scratchpad makes it a plain note", () => {
    const notes = create([], "pad", { workspace: { id: "w", name: "w" }, scratchpad: true })
    const r = applyOp(notes, { kind: "setWorkspace", id: "pad", workspace: null }, ui)
    expect(r.note!.scratchpad).toBe(false)
  })

  test("line edits: replace, delete, toggle", () => {
    let notes = create([], "a", { body: "# Todo\n- [ ] one\n- [x] two\nend" })
    notes = applyOp(notes, { kind: "toggleCheck", id: "a", index: 1 }, ui).notes
    notes = applyOp(notes, { kind: "toggleCheck", id: "a", index: 2 }, ui).notes
    expect(notes[0]!.body).toBe("# Todo\n- [x] one\n- [ ] two\nend")
    notes = applyOp(notes, { kind: "replaceLine", id: "a", index: 3, text: "fin\nmore" }, ui).notes
    notes = applyOp(notes, { kind: "deleteLine", id: "a", index: 0 }, ui).notes
    expect(notes[0]!.body).toBe("- [x] one\n- [ ] two\nfin\nmore")
    expect(() => applyOp(notes, { kind: "deleteLine", id: "a", index: 9 }, ui)).toThrow(NoteError)
  })

  test("limits and unknown ids are typed errors", () => {
    expect(() => applyOp([], { kind: "append", id: "nope", text: "x" }, ui)).toThrow(/no note/)
    const notes = create([], "a")
    expect(() => applyOp(notes, { kind: "append", id: "a", text: "x".repeat(LIMITS.appendChars + 1) }, ui)).toThrow(NoteError)
    expect(() => applyOp(notes, { kind: "setBody", id: "a", body: "x".repeat(LIMITS.bodyChars + 1) }, ui)).toThrow(NoteError)
    expect(() => applyOp(notes, { kind: "create", id: "a" }, ui)).toThrow(NoteError)
  })

  test("never mutates its input (property check over random op sequences)", () => {
    let seed = 7
    const rand = (n: number) => (seed = (seed * 1103515245 + 12345) % 2147483648) % n
    let notes: Note[] = []
    for (let i = 0; i < 400; i++) {
      deepFreeze(notes) // applyOp writing to its input would throw here (modules are strict)
      const ids = notes.map((n) => n.id)
      const id = ids.length && rand(4) ? ids[rand(ids.length)]! : `n${i}`
      const ops: NoteOp[] = [
        { kind: "create", id: `n${i}`, body: `line ${i}`, workspace: rand(2) ? { id: `w${rand(3)}`, name: "w" } : null, scratchpad: rand(2) === 1 },
        { kind: "append", id, text: `more ${i}` },
        { kind: "setPinned", id, pinned: rand(2) === 1 },
        { kind: "deleteLine", id, index: 0 },
        { kind: "delete", id }
      ]
      try {
        notes = applyOp(notes, ops[rand(ops.length)]!, at(i)).notes
      } catch (e) {
        expect(e).toBeInstanceOf(NoteError)
      }
      // Invariants: unique ids, at most one scratchpad per workspace, revisions positive.
      expect(new Set(notes.map((n) => n.id)).size).toBe(notes.length)
      const pads = notes.filter((n) => n.scratchpad).map((n) => n.workspace!.id)
      expect(new Set(pads).size).toBe(pads.length)
      expect(notes.every((n) => n.revision >= 1)).toBe(true)
    }
  })
})

describe("text helpers", () => {
  test("appendText adds a line", () => {
    expect(appendText("", "a")).toBe("a")
    expect(appendText("a", "b")).toBe("a\nb")
    expect(appendText("a\n", "b  \n\n")).toBe("a\nb")
    expect(appendText("a", "   ")).toBe("a")
  })

  test("deriveTitle: first heading, else first prose line outside fences", () => {
    expect(deriveTitle("intro\n## Deploy *plan*\nx")).toBe("Deploy plan")
    expect(deriveTitle("```\ncode\n```\n- [ ] ship [it](https://x)")).toBe("ship it")
    expect(deriveTitle("\n---\n")).toBe("")
  })

  test("preview skips headings, fences and the derived title line", () => {
    expect(previewOf({ title: "", body: "Groceries\n- milk\n- eggs" })).toBe("milk · eggs")
    expect(previewOf({ title: "T", body: "# H\n```\nx\n```\nbody" })).toBe("body")
    expect(previewOf({ title: "T", body: "a".repeat(200) }, 20)).toHaveLength(20)
  })

  test("toggleCheckLine", () => {
    expect(toggleCheckLine("  - [ ] a")).toBe("  - [x] a")
    expect(toggleCheckLine("* [X] a")).toBe("* [ ] a")
    expect(toggleCheckLine("plain")).toBe("plain")
  })

  test("export: file name and markdown", () => {
    const n = create([], "a", { title: "Release Plan: v2", body: "steps" })[0]!
    expect(fileNameOf(n)).toBe("release-plan-v2.md")
    expect(toMarkdown(n)).toBe("# Release Plan: v2\n\nsteps\n")
    const ja = create([], "b", { title: "買い物 リスト" })[0]!
    expect(fileNameOf(ja)).toBe("買い物-リスト.md")
    const headed = create([], "c", { title: "Plan", body: "# Plan\nx" })[0]!
    expect(toMarkdown(headed)).toBe("# Plan\nx\n")
  })
})

describe("search and sort", () => {
  let notes = create([], "a", { title: "Deploy checklist", body: "rotate keys\nupdate dns" }, 100)
  notes = create(notes, "b", { body: "dns notes for the api workspace", workspace: { id: "w", name: "api" } }, 200)
  notes = create(notes, "c", { body: "lunch" }, 300)

  test("every word must match; title hits rank first", () => {
    // b's derived title starts with "dns"; a has it only in the body.
    expect(searchNotes(notes, "dns").map((h) => h.note.id)).toEqual(["b", "a"])
    expect(searchNotes(notes, "dns api").map((h) => h.note.id)).toEqual(["b"])
    expect(searchNotes(notes, "deploy").map((h) => h.note.id)).toEqual(["a"])
    expect(searchNotes(notes, "zzz")).toEqual([])
  })

  test("snippet comes from the matching body line", () => {
    expect(searchNotes(notes, "rotate")[0]!.snippet).toBe("rotate keys")
  })

  test("sort: pinned first, then most recent", () => {
    const pinned = applyOp(notes, { kind: "setPinned", id: "a", pinned: true }, ui).notes
    expect(sortNotes(pinned).map((n) => n.id)).toEqual(["a", "c", "b"])
    expect(sortNotes(notes, "title").map((n) => n.id)).toEqual(["a", "b", "c"])
  })

  test("summaries never include the body", () => {
    expect(Object.keys(summaryOf(notes[0]!))).not.toContain("body")
  })
})

describe("storage document", () => {
  test("parseDocument tolerates junk and duplicates", () => {
    const notes = parseDocument({ notes: [{ id: "a", body: "x\r\ny", pinned: true }, { id: "a" }, null, { body: "no id" }, { id: "b", scratchpad: true }] })
    expect(notes.map((n) => n.id)).toEqual(["a", "b"])
    expect(notes[0]!.body).toBe("x\ny")
    expect(notes[1]!.scratchpad).toBe(false)
    expect(parseDocument(null)).toEqual([])
    expect(parseDocument("garbage")).toEqual([])
  })
})

describe("markdown-lite", () => {
  test("classifies lines", () => {
    const kinds = parseLines("# T\n- a\n  - [x] b\n1. c\n> q\n```js\nlet x\n```\n\n---\ntext").map((l) => [l.kind, l.level, l.text])
    expect(kinds).toEqual([
      ["heading", 1, "T"],
      ["bullet", 0, "a"],
      ["check", 1, "b"],
      ["number", 0, "c"],
      ["quote", 0, "q"],
      ["fence", 0, "js"],
      ["code", 0, "let x"],
      ["fence", 0, ""],
      ["blank", 0, ""],
      ["rule", 0, ""],
      ["text", 0, "text"]
    ])
  })
})

describe("l10n", () => {
  test("every t() key used in src has a Japanese string", () => {
    const src = join(import.meta.dir, "../src")
    const files = [...readdirSync(src).filter((f) => f.endsWith(".ts")).map((f) => join(src, f)), ...readdirSync(join(src, "views")).map((f) => join(src, "views", f))]
    const used = new Set<string>()
    for (const f of files) for (const m of readFileSync(f, "utf8").matchAll(/\bt\("([\w.]+)"/g)) used.add(m[1]!)
    const ja = new Set(translatedKeys("ja"))
    expect([...used].filter((k) => !ja.has(k))).toEqual([])
  })

  test("placeholders fill in both languages", () => {
    setLanguage("ja-JP")
    expect(t("action.showMore", "Show {n} more lines", { n: 3 })).toBe("あと3行を表示")
    setLanguage("fr")
    expect(t("action.showMore", "Show {n} more lines", { n: 3 })).toBe("Show 3 more lines")
    setLanguage("en")
  })
})
