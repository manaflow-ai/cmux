import { afterEach, describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
import { setLanguage, t } from "../src/l10n.ts"
import { parseLines } from "../src/markdown.ts"
import { applyEdits, fileNameOf, fromMarkdown, lineRange, rebaseLine, toggleCheckLine, toggleEdit, toMarkdown, uniqueFileNames } from "../src/model.ts"

describe("line edits", () => {
  const body = "# Plan\n- [ ] one\n  - [x] two\ntext"
  test("lineRange and toggleEdit address one character of the base text", () => {
    expect(lineRange(body, 1)).toEqual({ start: 7, end: 16 })
    expect(lineRange(body, 3)).toEqual({ start: 29, end: 33 })
    expect(lineRange(body, 4)).toBeNull()
    expect(toggleEdit(body, 1)).toEqual({ start: 10, end: 11, text: "x" })
    expect(applyEdits(body, [toggleEdit(body, 2)!])).toBe("# Plan\n- [ ] one\n  - [ ] two\ntext")
    expect(toggleEdit(body, 0)).toBeNull()
    expect(toggleCheckLine("* [X] done")).toBe("* [ ] done")
  })

  test("rebaseLine finds the same line in a newer text, or gives up", () => {
    expect(rebaseLine("a\n- [ ] x\nb", 1, "- [ ] x")).toBe(1)
    expect(rebaseLine("new\na\n- [ ] x\nb", 1, "- [ ] x")).toBe(2)
    expect(rebaseLine("a\nb", 1, "- [ ] x")).toBeNull()
    expect(rebaseLine("- [ ] x\nmid\n- [ ] x", 1, "- [ ] x")).toBeNull() // two equally near copies: ambiguous
  })

  test("applyEdits applies several edits by their base offsets", () => {
    expect(applyEdits("abcdef", [{ start: 0, end: 1, text: "X" }, { start: 4, end: 6, text: "" }])).toBe("Xbcd")
  })
})

describe("markdown files", () => {
  test("export names are unique slugs; titles become a heading once", () => {
    expect(fileNameOf({ title: "Deploy: step 1 / 2" })).toBe("deploy-step-1-2.md")
    expect(fileNameOf({ title: "会議メモ" })).toBe("会議メモ.md")
    expect(fileNameOf({ title: "!!!" })).toBe("note.md")
    expect(uniqueFileNames([{ title: "Ideas" }, { title: "ideas" }, { title: "Ideas" }])).toEqual(["ideas.md", "ideas-2.md", "ideas-3.md"])
    expect(toMarkdown({ title: "Plan", title_explicit: true, body: "step\n" })).toBe("# Plan\n\nstep\n")
    expect(toMarkdown({ title: "Plan", title_explicit: true, body: "# Plan\nstep" })).toBe("# Plan\nstep\n")
    expect(toMarkdown({ title: "step", title_explicit: false, body: "step" })).toBe("step\n")
  })

  test("import takes a leading level-1 heading as the title (the inverse of export)", () => {
    expect(fromMarkdown("﻿\n# Runbook #\r\n\r\nrestart\r\n")).toEqual({ title: "Runbook", body: "restart" })
    expect(fromMarkdown("## Sub\ntext")).toEqual({ body: "## Sub\ntext" })
    expect(fromMarkdown("- [ ] ship\n")).toEqual({ body: "- [ ] ship" })
    const round = fromMarkdown(toMarkdown({ title: "Plan", title_explicit: true, body: "a\nb" }))
    expect(round).toEqual({ title: "Plan", body: "a\nb" })
  })
})

describe("markdown-lite", () => {
  test("classifies lines", () => {
    const lines = parseLines("# T\n- [ ] a\n- b\n1. c\n> q\n```\ncode\n```\n---\n\ntext")
    expect(lines.map((l) => l.kind)).toEqual(["heading", "check", "bullet", "number", "quote", "fence", "code", "fence", "rule", "blank", "text"])
  })
})

describe("localization", () => {
  const root = join(import.meta.dir, "..")
  const table = (lang: string) => JSON.parse(readFileSync(join(root, "strings", `${lang}.json`), "utf8")) as Record<string, string>
  const files = (dir: string): string[] => readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? files(join(dir, n)) : n.endsWith(".ts") ? [join(dir, n)] : []))
  const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort()
  afterEach(() => setLanguage(null))

  test("en and ja match, and every key the code uses exists", () => {
    const en = table("en")
    const ja = table("ja")
    expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort())
    for (const key of Object.keys(en)) expect([key, placeholders(ja[key]!)]).toEqual([key, placeholders(en[key]!)])
    const used = new Set<string>()
    for (const file of files(join(root, "src"))) for (const m of readFileSync(file, "utf8").matchAll(/\bt\(\s*"([\w.-]+)"/g)) used.add(m[1]!)
    expect([...used].filter((k) => !(k in en))).toEqual([])
    expect(Object.keys(en).filter((k) => !used.has(k))).toEqual([])
  })

  test("the bundled table follows the language", () => {
    setLanguage("ja")
    expect(t("export.done", { n: 3, folder: "x" })).toBe("3 件のメモを x に書き出しました")
  })
})
