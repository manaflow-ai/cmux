import { describe, expect, test } from "bun:test"
import { buildDragPayload, MAX_DRAG_ITEMS, planDrop, terminalInsertText } from "../src/model/drag.ts"
import type { Entry } from "../src/model/entries.ts"
import { shellQuote } from "../src/model/handles.ts"

const here = { conn: "conn_mac", root: "root_home", path: "src" }
const entries: Entry[] = [
  { name: "app", kind: "dir", size: null, mtime: 1 },
  { name: "notes.md", kind: "file", size: 10, mtime: 1 },
  { name: "link", kind: "symlink", size: null, mtime: 1, target_kind: "dir" }
]
const payload = (names = ["app", "notes.md"], rights: "read" | "read_write" = "read_write") => buildDragPayload(here, "~", names, entries, rights)

describe("drag payload", () => {
  test("typed file items with handles and display paths, never absolute paths", () => {
    const p = payload(["app", "notes.md", "link", "gone"])
    expect(p.kinds).toEqual(["file"])
    expect(p.items.map((i) => [i.ref.path, i.display, i.dir])).toEqual([
      ["src/app", "~/src/app", true],
      ["src/notes.md", "~/src/notes.md", false],
      ["src/link", "~/src/link", true]
    ])
    expect(p.items.every((i) => i.ref.conn === "conn_mac" && i.ref.root === "root_home")).toBe(true)
    expect(p.operations).toEqual(["copy", "move", "reference"])
  })

  test("a read-only root cannot offer move", () => {
    expect(payload(["notes.md"], "read").operations).toEqual(["copy", "reference"])
  })

  test("large selections are capped and marked", () => {
    const many: Entry[] = Array.from({ length: MAX_DRAG_ITEMS + 5 }, (_, i) => ({ name: `f${i}`, kind: "file", size: 1, mtime: 1 }))
    const p = buildDragPayload(here, "~", many.map((e) => e.name), many, "read")
    expect(p.items).toHaveLength(MAX_DRAG_ITEMS)
    expect(p.truncated).toBe(true)
  })
})

describe("drop plans", () => {
  test("same host folder: move by default, copy offered", () => {
    const plan = planDrop(payload(["notes.md"]), { kind: "folder", location: { ...here, path: "docs" }, writable: true }, "read_write")
    expect(plan).toEqual({ action: "move", to: { ...here, path: "docs" }, crossHost: false, alternatives: ["copy", "move"] })
  })

  test("another host: copy by default", () => {
    const plan = planDrop(payload(["notes.md"]), { kind: "folder", location: { conn: "conn_vm", root: "root_vm", path: "" }, writable: true }, "read_write")
    expect(plan.action).toBe("copy")
    expect(plan.action === "copy" && plan.crossHost).toBe(true)
  })

  test("refusals: read-only target, into itself, same place, empty", () => {
    expect(planDrop(payload(), { kind: "folder", location: here, writable: false }, "read_write")).toEqual({ action: "refuse", reason: "read_only" })
    expect(planDrop(payload(["app"]), { kind: "folder", location: { ...here, path: "src/app/lib" }, writable: true }, "read_write")).toEqual({ action: "refuse", reason: "into_itself" })
    expect(planDrop(payload(["notes.md"]), { kind: "folder", location: here, writable: true }, "read_write")).toEqual({ action: "refuse", reason: "same_place" })
    expect(planDrop(payload([]), { kind: "terminal", conn: "conn_mac" }, "read")).toEqual({ action: "refuse", reason: "empty" })
  })

  test("terminal: insert on the same host, copy first on another host", () => {
    expect(planDrop(payload(["notes.md"]), { kind: "terminal", conn: "conn_mac" }, "read").action).toBe("insert_path")
    expect(planDrop(payload(["notes.md"]), { kind: "terminal", conn: "conn_vm" }, "read")).toMatchObject({ action: "copy_then_insert", to: "terminal_drop_folder" })
  })

  test("agent: attach with the intersection of rights", () => {
    expect(planDrop(payload(["notes.md"]), { kind: "agent", accepts: ["file"], grant: "read_write" }, "read")).toMatchObject({ action: "attach", rights: "read" })
    expect(planDrop(payload(["notes.md"]), { kind: "agent", accepts: ["file"], grant: "read_write" }, "read_write")).toMatchObject({ action: "attach", rights: "read_write" })
    expect(planDrop(payload(["notes.md"]), { kind: "agent", accepts: ["text"], grant: "read" }, "read")).toEqual({ action: "refuse", reason: "kind_not_accepted" })
    expect(planDrop(payload(["notes.md"]), { kind: "agent", accepts: ["file"], grant: null }, "read")).toEqual({ action: "refuse", reason: "no_file_access" })
  })

  test("terminal text is quoted per path", () => {
    expect(terminalInsertText(["/srv/a.txt", "/srv/my file.txt"], shellQuote)).toBe("/srv/a.txt '/srv/my file.txt'")
  })
})
