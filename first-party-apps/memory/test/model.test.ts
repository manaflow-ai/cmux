import { describe, expect, test } from "bun:test"
import { applyEdits, applyIntent, toEdits } from "../src/model/edits.ts"
import { parseEntries } from "../src/model/entries.ts"
import { agentsLabel, AGENTS_MD_READERS, classify, fileRank } from "../src/model/kinds.ts"
import { busyReview, type ReviewState, reduceReview } from "../src/model/review.ts"

describe("memory file classification", () => {
  const cases: Array<[("user" | "project"), string, string[] | null, string | null]> = [
    ["user", ".claude/CLAUDE.md", ["claude"], "instructions"],
    ["user", ".claude/projects/-work-api/memory/MEMORY.md", ["claude"], "memoryIndex"],
    ["user", ".claude/projects/-work-api/memory/release.md", ["claude"], "memoryTopic"],
    ["user", ".codex/AGENTS.md", ["codex"], "instructions"],
    ["user", ".codex/AGENTS.override.md", ["codex"], "override"],
    ["user", ".config/opencode/AGENTS.md", ["opencode"], "instructions"],
    ["user", ".gemini/GEMINI.md", ["gemini"], "instructions"],
    ["project", "CLAUDE.md", ["claude"], "instructions"],
    ["project", ".claude/CLAUDE.md", ["claude"], "instructions"],
    ["project", "CLAUDE.local.md", ["claude"], "local"],
    ["project", "AGENTS.md", AGENTS_MD_READERS, "instructions"],
    ["project", "services/billing/AGENTS.md", AGENTS_MD_READERS, "instructions"],
    ["project", "AGENTS.override.md", ["codex"], "override"],
    ["project", "GEMINI.md", ["gemini"], "instructions"],
    ["project", ".github/copilot-instructions.md", ["copilot"], "instructions"],
    ["project", ".cursor/rules/style.mdc", ["cursor"], "rules"],
    // Not memory: other files, user files in a project root, escapes.
    ["project", "README.md", null, null],
    ["user", ".claude/settings.json", null, null],
    ["user", "AGENTS.md", null, null],
    ["project", ".claude/projects/x/memory/MEMORY.md", null, null],
    ["project", "../AGENTS.md", null, null],
    ["project", "a//AGENTS.md", null, null]
  ]
  for (const [root, path, agents, kind] of cases) {
    test(`${root}:${path}`, () => {
      const c = classify(root, path)
      if (agents === null) expect(c).toBeNull()
      else expect(c).toMatchObject({ agents, kind })
    })
  }
  test("Claude project memory carries its slug", () => {
    expect(classify("user", ".claude/projects/-work-api/memory/MEMORY.md")?.slug).toBe("-work-api")
  })
  test("rank: project root files, then nested, then user; index before topics", () => {
    const r = (root: "user" | "project", p: string) => fileRank(root, p, classify(root, p)!)
    expect(r("project", "AGENTS.md")).toBeLessThan(r("project", "services/AGENTS.md"))
    expect(r("project", "services/AGENTS.md")).toBeLessThan(r("user", ".codex/AGENTS.md"))
    expect(r("user", ".claude/projects/s/memory/MEMORY.md")).toBeLessThan(r("user", ".claude/projects/s/memory/a.md"))
  })
  test("agent labels", () => {
    expect(agentsLabel(["claude"])).toBe("Claude Code")
    expect(agentsLabel(AGENTS_MD_READERS)).toBe("Codex, OpenCode +3")
  })
})

const doc = ["---", "name: notes", "---", "# Notes", "", "## Build", "- Run tests first.", "  Takes 40 s.", "- Never edit generated/.", "", "Plain paragraph", "continues here.", "", "```", "- not a bullet", "```", "", "## Deploy", "1. Tag from main.", ""].join("\n")

describe("entries", () => {
  test("bullets with continuation, paragraphs, headings, fences, front matter skipped", () => {
    const e = parseEntries(doc)
    expect(e.map((x) => [x.text, x.section, x.bullet, x.start, x.end])).toEqual([
      ["Run tests first.\nTakes 40 s.", "Build", true, 7, 9],
      ["Never edit generated/.", "Build", true, 9, 10],
      ["Plain paragraph\ncontinues here.", "Build", false, 11, 13],
      ["```\n- not a bullet\n```", "Build", false, 14, 17],
      ["Tag from main.", "Deploy", true, 19, 20]
    ])
  })
  test("empty text", () => {
    expect(parseEntries("")).toEqual([])
  })
})

describe("edit intents", () => {
  test("append adds a bullet at the end, with a blank line after prose", () => {
    expect(applyIntent("- a\n", { op: "append", text: "b" })).toEqual({ ok: true, text: "- a\n- b\n" })
    expect(applyIntent("# T\n\nprose\n", { op: "append", text: "  b  c " })).toEqual({ ok: true, text: "# T\n\nprose\n\n- b c\n" })
    expect(applyIntent("", { op: "append", text: "first" })).toEqual({ ok: true, text: "- first\n" })
    expect(applyIntent("- a\n", { op: "append", text: "   " })).toEqual({ ok: false, reason: "empty" })
  })
  test("append under a section goes after that section's last entry", () => {
    const r = applyIntent(doc, { op: "append", text: "Lint too.", section: "Build" })
    expect(r.ok && r.text.split("\n").indexOf("- Lint too.")).toBe(16)
    expect(r.ok && parseEntries(r.text).filter((e) => e.section === "Build").length).toBe(5)
  })
  test("remove and replace match by text and keep the bullet style", () => {
    const removed = applyIntent(doc, { op: "remove", entry: "Run tests first. Takes 40 s." })
    expect(removed.ok && removed.text.includes("Takes 40 s.")).toBe(false)
    expect(removed.ok && removed.text.includes("- Never edit generated/.")).toBe(true)
    const replaced = applyIntent(doc, { op: "replace", entry: "Tag from main.", text: "Tag from release branches." })
    expect(replaced.ok && replaced.text.includes("1. Tag from release branches.")).toBe(true)
  })
  test("an entry that is gone (an agent changed the file) is reported, not guessed", () => {
    expect(applyIntent(doc, { op: "remove", entry: "nothing like this" })).toEqual({ ok: false, reason: "gone" })
  })
  test("the same intent rebases onto a changed file", () => {
    const changed = doc.replace("## Build", "## Build\n- New line from an agent.")
    const r = applyIntent(changed, { op: "remove", entry: "Never edit generated/." })
    expect(r.ok && r.text.includes("New line from an agent.")).toBe(true)
    expect(r.ok && r.text.includes("Never edit generated/.")).toBe(false)
  })
  test("trash empties the text (the review shows every line removed)", () => {
    expect(applyIntent(doc, { op: "trash" })).toEqual({ ok: true, text: "" })
  })
})

describe("line edits for document.edit", () => {
  const random = (seed: number) => () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff)
  test("toEdits then applyEdits reproduces the new text (200 random cases)", () => {
    const rnd = random(7)
    for (let n = 0; n < 200; n++) {
      const before = Array.from({ length: Math.floor(rnd() * 12) }, () => `l${Math.floor(rnd() * 5)}`).join("\n")
      const after = Array.from({ length: Math.floor(rnd() * 12) }, () => `l${Math.floor(rnd() * 5)}`).join("\n")
      const b = before ? before + "\n" : "", a = after ? after + "\n" : ""
      expect(applyEdits(b, toEdits(b, a))).toBe(a)
    }
  })
  test("edits are minimal and ordered", () => {
    expect(toEdits("a\nb\nc\n", "a\nx\nc\nd\n")).toEqual([
      { start: 2, end: 3, lines: ["x"] },
      { start: 4, end: 4, lines: ["d"] }
    ])
    expect(toEdits("same\n", "same\n")).toEqual([])
  })
})

describe("review state machine", () => {
  const file = { root: "root_1", path: "AGENTS.md", label: "AGENTS.md" }
  const intent = { op: "append" as const, text: "x" }
  const prepared = { doc: "doc_1", revision: "rev_1", before: "a\n", after: "a\n- x\n" }
  const review = reduceReview(reduceReview({ phase: "idle" }, { type: "ask", file, intent, title: "Add" }), { type: "prepared", prepared })
  test("ask -> prepared -> apply -> applied", () => {
    expect(review).toMatchObject({ phase: "review", note: null, revision: "rev_1" })
    const applying = reduceReview(review, { type: "apply" })
    expect(busyReview(applying)).toBe(true)
    expect(reduceReview(applying, { type: "applied" }).phase).toBe("applied")
  })
  test("stale rebases once, then fails", () => {
    const again = reduceReview(reduceReview(reduceReview(review, { type: "apply" }), { type: "stale" }), { type: "prepared", prepared: { ...prepared, revision: "rev_2" } })
    expect(again).toMatchObject({ phase: "review", note: "rebased", revision: "rev_2" })
    const failed = reduceReview(reduceReview(again, { type: "apply" }), { type: "stale" }) as Extract<ReviewState, { phase: "failed" }>
    expect(failed.code).toBe("document.stale")
  })
  test("gone only while preparing; cancel never interrupts a save", () => {
    const preparing = reduceReview({ phase: "idle" }, { type: "ask", file, intent, title: "Add" })
    expect(reduceReview(preparing, { type: "gone" }).phase).toBe("gone")
    expect(reduceReview(review, { type: "gone" })).toBe(review)
    const applying = reduceReview(review, { type: "apply" })
    expect(reduceReview(applying, { type: "cancel" })).toBe(applying)
    expect(reduceReview(applying, { type: "ask", file, intent, title: "Again" })).toBe(applying)
  })
})
