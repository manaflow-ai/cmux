import { describe, expect, test } from "bun:test"
import type { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { callsOf, makeHost, tap, texts, visible } from "./harness.ts"

const M = "m1"
const ADD = "Add a line to this file…"

async function mount(fixture: string, exportName: string, settings: Record<string, unknown> = {}, overrides: Record<string, unknown> = {}) {
  const host = makeHost(fixture, settings, overrides)
  expect(host.mount(M, exportName, {})).toBe("")
  await host.settle(30)
  return host
}

async function submit(host: FakeHost, placeholder: string, text: string) {
  const id = host.findNode(M, (n) => n.type === "TextField" && n.props.placeholder === placeholder)!
  host.dispatch(M, id, "submit", { text, gesture: "gst_test" })
  await host.settle(15)
}

async function menu(host: FakeHost, text: string, title: string) {
  const [id, node] = visible(host, M).find(([, n]) => n.props.text === text && n.props.menu)!
  const index = (node.props.menu as Array<{ title?: string }>).findIndex((m) => m.title === title)
  host.dispatch(M, id, "menu", { path: [index], gesture: "gst_test" })
  await host.settle(15)
}

describe("variants", () => {
  for (const variant of ["files", "entries", "split"]) {
    test(`${variant}: memory files of every machine and project, non-memory files hidden`, async () => {
      const host = await mount(variant, "renderPane", { variant })
      const t = texts(host, M).join("\n")
      expect(t).toContain("AGENTS.md")
      expect(t).toContain("~/.claude/CLAUDE.md")
      expect(t).not.toContain("README.md")
      expect(t).not.toContain("settings.json")
      expect(callsOf(host, "memory.roots").map((c) => c.params.machine)).toEqual(["machine_mac01", "machine_srv01"])
      expect(callsOf(host, "memory.list").map((c) => c.params.root)).toEqual(["root_api01", "root_home01", "root_srvhome"])
      // Files are read only through handles: document.open takes a root handle and a relative path.
      for (const c of callsOf(host, "document.open")) expect(c.params.path.startsWith("/")).toBe(false)
    })
  }

  test("entries: every file's entries, filtered as you search", async () => {
    const host = await mount("entries", "renderPane", { variant: "entries" })
    await host.settle(30)
    expect(texts(host, M)).toContain("Money is stored in integer cents.")
    expect(texts(host, M)).toContain("Use rg instead of grep.")
  })
})

describe("every write shows a diff first", () => {
  test("add a line: diff, then Save sends document.edit with the base revision and the gesture", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await submit(host, ADD, "Integration tests need DATABASE_URL")
    expect(texts(host, M)).toContain("Add a line to AGENTS.md")
    expect(texts(host, M)).toContain("+ - Integration tests need DATABASE_URL")
    expect(callsOf(host, "document.edit")).toHaveLength(0)
    await tap(host, M, "Save")
    const [edit] = callsOf(host, "document.edit")
    expect(edit!.params).toEqual({ doc: "doc_01", base_revision: "rev_7", edits: [{ start: 11, end: 11, lines: ["- Integration tests need DATABASE_URL"] }] })
    expect(edit!.options.gesture).toBe("gst_test")
    expect(texts(host, M)).toContain("Saved")
    expect(texts(host, M)).toContain("Integration tests need DATABASE_URL")
  })

  test("delete a line from its menu", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await menu(host, "Never edit files under `generated/`; run `make gen` instead.", "Delete Line…")
    expect(texts(host, M)).toContain("Delete a line from AGENTS.md")
    await tap(host, M, "Save")
    expect(callsOf(host, "document.edit")[0]!.params.edits).toEqual([{ start: 5, end: 6, lines: [] }])
  })

  test("a stale save reads the file again and shows the edit on the new text", async () => {
    const host = await mount("stale", "renderPane", { variant: "files" })
    await submit(host, ADD, "Integration tests need DATABASE_URL")
    await tap(host, M, "Save")
    expect(texts(host, M)).toContain("An agent changed this file after the first preview. This is your edit on the new text.")
    await tap(host, M, "Save")
    const edits = callsOf(host, "document.edit")
    expect(edits.map((e) => e.params.base_revision)).toEqual(["rev_7", "rev_9"])
    expect(edits[1]!.params.edits).toEqual([{ start: 12, end: 12, lines: ["- Integration tests need DATABASE_URL"] }])
    expect(texts(host, M)).toContain("Saved")
  })

  test("Move to Trash reviews the whole file and calls fs.trash with the gesture", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await tap(host, M, "Move to Trash…")
    expect(texts(host, M)).toContain("Move AGENTS.md to the Trash")
    expect(callsOf(host, "fs.trash")).toHaveLength(0)
    await tap(host, M, "Move to Trash")
    const [trash] = callsOf(host, "fs.trash")
    expect(trash!.params).toEqual({ root: "root_api01", paths: ["AGENTS.md"], expected_revisions: { "AGENTS.md": "rev_7" } })
    expect(trash!.options.gesture).toBe("gst_test")
  })

  test("Cancel writes nothing", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await submit(host, ADD, "x")
    await tap(host, M, "Cancel")
    expect(callsOf(host, "document.edit")).toHaveLength(0)
    expect(texts(host, M)).not.toContain("Add a line to AGENTS.md")
  })

  test("Open in Diffs asks the document host for a diff resource and opens the diff renderer", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await submit(host, ADD, "x")
    await tap(host, M, "Open in Diffs")
    expect(callsOf(host, "document.propose")[0]!.params).toMatchObject({ doc: "doc_01", base_revision: "rev_7" })
    expect(callsOf(host, "ui.open")[0]!.params).toEqual({ interface: "cmux.diff.renderer/1", props: { diff: "diff_mem01", layout: "unified" } })
  })
})

describe("search, section and states", () => {
  test("search uses the owner's memory.search over every root", async () => {
    const host = await mount("files", "renderPane", { variant: "files" })
    await submit(host, "Search memory", "database")
    expect(callsOf(host, "memory.search")[0]!.params).toEqual({ roots: ["root_api01", "root_home01", "root_srvhome"], query: "database", limit: 50 })
    expect(texts(host, M)).toContain("Database access goes through `store/`, never raw SQL in handlers.")
  })
  test("without memory.search, file names and read texts are searched locally", async () => {
    const host = await mount("files", "renderPane", { variant: "files" }, { "memory.search": { $error: { code: "operation.unsupported", message: "" } } })
    await submit(host, "Search memory", "flags")
    expect(texts(host, M)).toContain("- Feature flags live in `config/flags.yaml`.")
  })
  test("section: this machine's files only", async () => {
    const host = await mount("files", "renderSection")
    const titles = visible(host, M).filter(([, n]) => n.type === "Row").map(([, n]) => n.props.title)
    expect(titles).toContain("AGENTS.md")
    expect(titles.filter((x) => x === "~/.codex/AGENTS.md")).toHaveLength(1)
  })
  test("empty, error and missing op", async () => {
    expect(texts(await mount("empty", "renderPane"), M)).toContain("No agent memory files")
    expect(texts(await mount("error", "renderPane"), M)).toContain("Cannot find agent memory")
    expect(texts(await mount("missing", "renderPane"), M)).toContain("Agent memory is not available yet")
  })
  test("cycleVariant walks the three designs", async () => {
    const host = await mount("files", "renderPane", {}, { "app.settings.set": {} })
    host.global.__cmuxAppRunCommand("cycleVariant", "{}", 1)
    await host.settle(5)
    expect(host.commandResults.get(1)?.body.value.variant).toBe("entries")
  })
})
