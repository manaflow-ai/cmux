import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { MemoryStore, buildMemoryTools } from "../../../src/memory/index";
import type { MemoryRecord } from "../../../src/memory/index";

let tmpDir: string;
let globalDir: string;
let projectDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-memory-test-"));
  globalDir = path.join(tmpDir, "global");
  projectDir = path.join(tmpDir, "project");
  await fs.mkdir(globalDir, { recursive: true });
  await fs.mkdir(projectDir, { recursive: true });
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeStore(opts?: { noProject?: boolean }): MemoryStore {
  return new MemoryStore({
    globalDir,
    projectDir: opts?.noProject ? undefined : projectDir,
  });
}

async function readFile(p: string): Promise<string> {
  return Bun.file(p).text();
}

// ---------------------------------------------------------------------------
// save — creates file with frontmatter and updates MEMORY.md
// ---------------------------------------------------------------------------

describe("MemoryStore.save", () => {
  test("creates file with correct frontmatter", async () => {
    const store = makeStore();
    const record = await store.save({
      name: "my-note",
      description: "A test note",
      type: "user",
      body: "This is the body.",
      scope: "global",
    });

    expect(record.path).toBe(path.join(globalDir, "my-note.md"));
    const content = await readFile(record.path);
    expect(content).toContain("name: my-note");
    expect(content).toContain("description: A test note");
    expect(content).toContain("metadata:");
    expect(content).toContain("  type: user");
    expect(content).toContain("This is the body.");
  });

  test("updates MEMORY.md index after save", async () => {
    const store = makeStore();
    await store.save({
      name: "alpha",
      description: "Alpha note",
      type: "reference",
      body: "alpha body",
      scope: "global",
    });

    const indexPath = path.join(globalDir, "MEMORY.md");
    const index = await readFile(indexPath);
    expect(index).toContain("# Memory index");
    expect(index).toContain("[alpha](alpha.md)");
    expect(index).toContain("Alpha note");
  });

  test("index is sorted alphabetically with multiple entries", async () => {
    const store = makeStore();
    await store.save({ name: "zebra", description: "Z", type: "user", body: "", scope: "global" });
    await store.save({ name: "apple", description: "A", type: "user", body: "", scope: "global" });
    await store.save({ name: "mango", description: "M", type: "user", body: "", scope: "global" });

    const indexPath = path.join(globalDir, "MEMORY.md");
    const index = await readFile(indexPath);
    const alphaPos = index.indexOf("[apple]");
    const mangoPos = index.indexOf("[mango]");
    const zebraPos = index.indexOf("[zebra]");
    expect(alphaPos).toBeLessThan(mangoPos);
    expect(mangoPos).toBeLessThan(zebraPos);
  });
});

// ---------------------------------------------------------------------------
// list — returns parsed records from both dirs
// ---------------------------------------------------------------------------

describe("MemoryStore.list", () => {
  test("returns records from both global and project dirs", async () => {
    const store = makeStore();
    await store.save({ name: "g-note", description: "Global", type: "user", body: "g", scope: "global" });
    await store.save({ name: "p-note", description: "Project", type: "project", body: "p", scope: "project" });

    const records = await store.list();
    const names = records.map((r) => r.name);
    expect(names).toContain("g-note");
    expect(names).toContain("p-note");
  });

  test("records have correct scope set", async () => {
    const store = makeStore();
    await store.save({ name: "g-note", description: "Global", type: "user", body: "", scope: "global" });
    await store.save({ name: "p-note", description: "Project", type: "project", body: "", scope: "project" });

    const records = await store.list();
    const g = records.find((r) => r.name === "g-note");
    const p = records.find((r) => r.name === "p-note");
    expect(g?.scope).toBe("global");
    expect(p?.scope).toBe("project");
  });

  test("returns empty array when no memories exist", async () => {
    const store = makeStore();
    const records = await store.list();
    expect(records).toHaveLength(0);
  });

  test("skips malformed files without crashing", async () => {
    const store = makeStore();
    // Write a valid memory first
    await store.save({ name: "valid", description: "Valid note", type: "user", body: "ok", scope: "global" });
    // Write a malformed file (no frontmatter)
    await Bun.write(path.join(globalDir, "broken.md"), "just plain text with no frontmatter");

    const records = await store.list();
    // Only the valid record should be returned
    expect(records).toHaveLength(1);
    expect(records[0].name).toBe("valid");
  });

  test("skips malformed file with incomplete frontmatter", async () => {
    const store = makeStore();
    await Bun.write(
      path.join(globalDir, "incomplete.md"),
      "---\ndescription: missing name\nmetadata:\n  type: user\n---\nbody"
    );

    const records = await store.list();
    expect(records).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// get — retrieves by name
// ---------------------------------------------------------------------------

describe("MemoryStore.get", () => {
  test("returns the correct record by name", async () => {
    const store = makeStore();
    await store.save({ name: "find-me", description: "Find me", type: "feedback", body: "found!", scope: "global" });

    const record = await store.get("find-me");
    expect(record).not.toBeNull();
    expect(record!.name).toBe("find-me");
    expect(record!.body).toBe("found!");
    expect(record!.type).toBe("feedback");
  });

  test("returns null for nonexistent name", async () => {
    const store = makeStore();
    const record = await store.get("nonexistent");
    expect(record).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// remove — deletes file and updates index
// ---------------------------------------------------------------------------

describe("MemoryStore.remove", () => {
  test("deletes the file and returns true", async () => {
    const store = makeStore();
    await store.save({ name: "to-delete", description: "Delete me", type: "user", body: "", scope: "global" });

    const filePath = path.join(globalDir, "to-delete.md");
    expect(await Bun.file(filePath).exists()).toBe(true);

    const result = await store.remove("to-delete");
    expect(result).toBe(true);
    expect(await Bun.file(filePath).exists()).toBe(false);
  });

  test("updates MEMORY.md after removal", async () => {
    const store = makeStore();
    await store.save({ name: "keep", description: "Keep me", type: "user", body: "", scope: "global" });
    await store.save({ name: "gone", description: "Gone soon", type: "user", body: "", scope: "global" });

    await store.remove("gone");

    const indexPath = path.join(globalDir, "MEMORY.md");
    const index = await readFile(indexPath);
    expect(index).toContain("[keep]");
    expect(index).not.toContain("[gone]");
  });

  test("returns false when memory does not exist", async () => {
    const store = makeStore();
    const result = await store.remove("ghost");
    expect(result).toBe(false);
  });

  test("removes from project scope", async () => {
    const store = makeStore();
    await store.save({ name: "proj-mem", description: "Project mem", type: "project", body: "", scope: "project" });

    const filePath = path.join(projectDir, "proj-mem.md");
    expect(await Bun.file(filePath).exists()).toBe(true);

    const result = await store.remove("proj-mem");
    expect(result).toBe(true);
    expect(await Bun.file(filePath).exists()).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// scope isolation — save goes to correct dir
// ---------------------------------------------------------------------------

describe("scope isolation", () => {
  test("global scope writes to globalDir", async () => {
    const store = makeStore();
    const record = await store.save({
      name: "global-only",
      description: "In global",
      type: "user",
      body: "",
      scope: "global",
    });
    expect(record.path.startsWith(globalDir)).toBe(true);
    expect(await Bun.file(path.join(projectDir, "global-only.md")).exists()).toBe(false);
  });

  test("project scope writes to projectDir", async () => {
    const store = makeStore();
    const record = await store.save({
      name: "proj-only",
      description: "In project",
      type: "project",
      body: "",
      scope: "project",
    });
    expect(record.path.startsWith(projectDir)).toBe(true);
    expect(await Bun.file(path.join(globalDir, "proj-only.md")).exists()).toBe(false);
  });

  test("throws when saving to project scope with no projectDir", async () => {
    const store = makeStore({ noProject: true });
    expect(
      store.save({ name: "oops", description: "No project", type: "user", body: "", scope: "project" })
    ).rejects.toThrow("No projectDir");
  });
});

// ---------------------------------------------------------------------------
// buildMemoryTools
// ---------------------------------------------------------------------------

describe("buildMemoryTools", () => {
  test("returns three tools with correct names", () => {
    const store = makeStore();
    const tools = buildMemoryTools(store);
    const names = tools.map((t) => t.name);
    expect(names).toContain("memory_list");
    expect(names).toContain("memory_save");
    expect(names).toContain("memory_remove");
    expect(tools).toHaveLength(3);
  });

  test("memory_list returns 'No memories' when empty", async () => {
    const store = makeStore();
    const tools = buildMemoryTools(store);
    const listTool = tools.find((t) => t.name === "memory_list")!;
    const result = await (listTool.run as Function)({}, {});
    expect(result.content).toContain("No memories");
  });

  test("memory_save stores a record via tool", async () => {
    const store = makeStore();
    const tools = buildMemoryTools(store);
    const saveTool = tools.find((t) => t.name === "memory_save")!;

    const result = await (saveTool.run as Function)(
      { name: "tool-saved", description: "Via tool", type: "user", body: "hello", scope: "global" },
      {}
    );
    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("tool-saved");

    const record = await store.get("tool-saved");
    expect(record).not.toBeNull();
    expect(record!.body).toBe("hello");
  });

  test("memory_remove removes a record via tool", async () => {
    const store = makeStore();
    await store.save({ name: "rm-me", description: "Remove via tool", type: "user", body: "", scope: "global" });

    const tools = buildMemoryTools(store);
    const removeTool = tools.find((t) => t.name === "memory_remove")!;
    const result = await (removeTool.run as Function)({ name: "rm-me" }, {});

    expect(result.isError).toBeUndefined();
    expect(result.content).toContain("rm-me");
    expect(await store.get("rm-me")).toBeNull();
  });

  test("memory_list shows saved memories", async () => {
    const store = makeStore();
    await store.save({ name: "show-me", description: "Visible", type: "reference", body: "", scope: "global" });

    const tools = buildMemoryTools(store);
    const listTool = tools.find((t) => t.name === "memory_list")!;
    const result = await (listTool.run as Function)({}, {});
    expect(result.content).toContain("show-me");
    expect(result.content).toContain("Visible");
  });
});

// ---------------------------------------------------------------------------
// indexMarkdown
// ---------------------------------------------------------------------------

describe("MemoryStore.indexMarkdown", () => {
  test("assembles both indexes into one string", async () => {
    const store = makeStore();
    await store.save({ name: "g-idx", description: "Global idx", type: "user", body: "", scope: "global" });
    await store.save({ name: "p-idx", description: "Project idx", type: "project", body: "", scope: "project" });

    const md = await store.indexMarkdown();
    expect(md).toContain("Global memories");
    expect(md).toContain("Project memories");
    expect(md).toContain("[g-idx]");
    expect(md).toContain("[p-idx]");
  });
});
