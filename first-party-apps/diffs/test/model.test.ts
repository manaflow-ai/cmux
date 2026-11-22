import { describe, expect, test } from "bun:test"
import { diffLines, diffTexts, splitLines } from "../src/model/linediff.ts"
import * as review from "../src/model/review.ts"
import { cleanPath, parseUnifiedDiff } from "../src/model/unified.ts"
import { fixture } from "./harness.ts"

const patch = (fixture("split").ops["git.diff"] as { patch: string }).patch

describe("unified diff parser", () => {
  const files = parseUnifiedDiff(patch)

  test("files, statuses and counts", () => {
    expect(files.map((f) => [f.path, f.status, f.additions, f.deletions, f.binary])).toEqual([
      ["src/cache/lru.ts", "modified", 12, 2, false],
      ["src/server/routes.ts", "modified", 1, 1, false],
      ["docs/caching.md", "added", 5, 0, false],
      ["src/legacy/memo.ts", "deleted", 0, 4, false],
      ["assets/logo.png", "binary", 0, 0, true]
    ])
  })

  test("hunk headers and line numbers on both sides", () => {
    const [h1, h2] = files[0]!.hunks
    expect([h1!.oldStart, h1!.oldLines, h1!.newStart, h1!.newLines, h1!.section]).toEqual([12, 17, 12, 22, "export class LruCache<K, V> {"])
    expect(h1!.lines.filter((l) => l.kind !== "add").length).toBe(17)
    expect(h1!.lines.filter((l) => l.kind !== "del").length).toBe(22)
    const ctor = h1!.lines.find((l) => l.kind === "del")!
    expect([ctor.oldLine, ctor.newLine]).toEqual([14, null])
    const last = h1!.lines.at(-1)!
    expect([last.oldLine, last.newLine]).toEqual([28, 33])
    expect(h2!.newStart).toBe(45)
  })

  test("hunk ids are stable and distinct", () => {
    const again = parseUnifiedDiff(patch)
    expect(again[0]!.hunks.map((h) => h.id)).toEqual(files[0]!.hunks.map((h) => h.id))
    const ids = files.flatMap((f) => f.hunks.map((h) => h.id))
    expect(new Set(ids).size).toBe(ids.length)
  })

  test("rename, no newline at end, quoted paths, plain diff -u", () => {
    const renamed = parseUnifiedDiff(`diff --git a/old name.txt b/new name.txt
similarity index 90%
rename from old name.txt
rename to new name.txt
--- a/old name.txt
+++ b/new name.txt
@@ -1 +1 @@
-a
\\ No newline at end of file
+b
\\ No newline at end of file
`)
    expect(renamed[0]).toMatchObject({ path: "new name.txt", oldPath: "old name.txt", status: "renamed" })
    expect(renamed[0]!.hunks[0]!.lines.map((l) => [l.kind, l.noNewline])).toEqual([["del", true], ["add", true]])
    expect(cleanPath('"b/sp\\"ace.txt"')).toBe('sp"ace.txt')
    const plain = parseUnifiedDiff("--- a/x.txt\t2026-01-01\n+++ b/x.txt\t2026-01-02\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n")
    expect(plain).toHaveLength(1)
    expect(plain[0]).toMatchObject({ path: "x.txt", additions: 1, deletions: 1 })
  })

  test("garbage and empty input give no files", () => {
    expect(parseUnifiedDiff("")).toEqual([])
    expect(parseUnifiedDiff("hello\nworld\n")).toEqual([])
  })
})

describe("line diff", () => {
  const apply = (a: string[], b: string[]) => {
    const ops = diffLines(a, b)
    expect(ops.filter((o) => o.kind !== "add").map((o) => a[o.oldIndex])).toEqual(a)
    expect(ops.filter((o) => o.kind !== "del").map((o) => b[o.newIndex])).toEqual(b)
    return ops
  }

  test("edit scripts rebuild both sides", () => {
    apply([], [])
    apply(["a"], [])
    apply([], ["a"])
    apply(["a", "b", "c"], ["a", "x", "c"])
    apply(["a", "b", "c", "d"], ["b", "c", "d", "e"])
    const rnd = (seed: number) => Array.from({ length: 40 }, (_, i) => String((i * seed) % 7))
    apply(rnd(3), rnd(5))
  })

  test("minimal: one replaced line costs two edits", () => {
    expect(apply(["a", "b", "c"], ["a", "x", "c"]).filter((o) => o.kind !== "context")).toHaveLength(2)
  })

  test("hunks with context, merged when close, line numbers", () => {
    const before = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join("\n") + "\n"
    const after = before.replace("line 5\n", "line five\n").replace("line 9\n", "line nine\n").replace("line 25\n", "")
    const f = diffTexts("f.txt", before, after)
    expect(f.hunks).toHaveLength(2)
    expect([f.hunks[0]!.oldStart, f.hunks[0]!.newStart]).toEqual([2, 2])
    expect(f.hunks[1]!.lines.find((l) => l.kind === "del")).toMatchObject({ text: "line 25", oldLine: 25 })
    expect([f.additions, f.deletions]).toEqual([2, 3])
    expect(splitLines("a\r\nb\n")).toEqual(["a", "b"])
  })

  test("added and deleted files", () => {
    expect(diffTexts("n", "", "x\n").status).toBe("added")
    expect(diffTexts("n", "x\n", "").status).toBe("deleted")
  })
})

describe("review model", () => {
  const files = parseUnifiedDiff(patch).filter((f) => f.hunks.length)
  const lru = files[0]!
  const [h1, h2] = lru.hunks

  test("hunk decisions roll up to the file", () => {
    let s = review.emptyReview()
    expect(review.fileDecision(s, lru)).toBe("pending")
    s = review.decideHunk(s, h1!.id, "accept")
    expect(review.fileDecision(s, lru)).toBe("partial")
    s = review.decideHunk(s, h2!.id, "accept")
    expect(review.fileDecision(s, lru)).toBe("accept")
    s = review.decideHunk(s, h2!.id, "accept") // same decision again toggles it off (Undo)
    expect(review.fileDecision(s, lru)).toBe("partial")
    s = review.decideFile(s, lru, "reject")
    expect(review.fileDecision(s, lru)).toBe("reject")
  })

  test("unsent decisions: whole file when every hunk agrees, else per hunk; confirm clears them", () => {
    let s = review.decideFile(review.emptyReview(), lru, "accept")
    s = review.decideHunk(s, files[1]!.hunks[0]!.id, "reject")
    const unsent = review.unsentDecisions(s, files)
    expect(unsent).toEqual([{ path: "src/cache/lru.ts", decision: "accept" }, { path: "src/server/routes.ts", decision: "reject" }])
    s = review.confirm(s, files, unsent)
    expect(review.unsentDecisions(s, files)).toEqual([])
    s = review.decideHunk(s, h1!.id, "reject")
    expect(review.unsentDecisions(s, files)).toEqual([{ path: "src/cache/lru.ts", hunk: h1!.id, decision: "reject" }])
  })

  test("owner decisions seed a reopened review as confirmed", () => {
    const s = review.fromOwner(files, [{ path: "src/server/routes.ts", decision: "accept" }])
    expect(review.fileDecision(s, files[1]!)).toBe("accept")
    expect(review.unsentDecisions(s, files)).toEqual([])
  })

  test("counts and verdict", () => {
    let s = review.emptyReview()
    expect(review.verdict(s, files)).toBe("comment")
    for (const f of files) s = review.decideFile(s, f, "accept")
    expect(review.verdict(s, files)).toBe("approve")
    s = review.decideHunk(s, h1!.id, "reject")
    expect(review.verdict(s, files)).toBe("request_changes")
    expect(review.counts(s, files)).toMatchObject({ hunks: 5, accepted: 4, rejected: 1, pending: 0 })
  })

  test("comments attach to the new or old side of a line", () => {
    let s = review.addComment(review.emptyReview(), { path: lru.path, line: 14, side: "old", body: "  why?  " }, "c1")
    s = review.addComment(s, { path: lru.path, line: 15, side: "new", body: "ok" }, "c2")
    s = review.addComment(s, { path: lru.path, line: 1, side: "new", body: "   " }, "c3")
    expect(s.comments.map((c) => c.body)).toEqual(["why?", "ok"])
    const del = h1!.lines.find((l) => l.oldLine === 14 && l.kind === "del")!
    expect(review.commentsAt(s, lru.path, del).map((c) => c.id)).toEqual(["c1"])
    expect(review.removeComment(s, "c1").comments).toHaveLength(1)
  })

  test("side by side pairs deletions with the following additions", () => {
    const rows = review.sideBySide(h1!)
    const first = rows.find((r) => r.left?.kind === "del")!
    expect(first.right?.kind).toBe("add")
    const unpaired = rows.filter((r) => r.left === null)
    expect(unpaired.length).toBe(5) // 1 del vs 3 adds, then 1 del vs 4 adds
    expect(rows.filter((r) => r.left?.kind === "context").every((r) => r.left === r.right)).toBe(true)
  })
})
