import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { discoverProjectContext, renderProjectContext } from "@/cli/context";

let tmpHome: string;
let tmpCwd: string;
let origHome: string | undefined;

beforeEach(async () => {
  tmpHome = await mkdtemp(join(tmpdir(), "cmux101-ctx-home-"));
  tmpCwd = await mkdtemp(join(tmpdir(), "cmux101-ctx-cwd-"));
  origHome = process.env.HOME;
  process.env.HOME = tmpHome;
});

afterEach(async () => {
  process.env.HOME = origHome;
  await rm(tmpHome, { recursive: true, force: true });
  await rm(tmpCwd, { recursive: true, force: true });
});

describe("discoverProjectContext", () => {
  test("finds CLAUDE.md in cwd as project scope", async () => {
    const content = "# My Project\nAgent notes here.";
    await writeFile(join(tmpCwd, "CLAUDE.md"), content, "utf-8");

    const ctx = await discoverProjectContext(tmpCwd);
    const projectFiles = ctx.files.filter((f) => f.scope === "project");
    expect(projectFiles.length).toBeGreaterThanOrEqual(1);
    const found = projectFiles.find((f) => f.path === join(tmpCwd, "CLAUDE.md"));
    expect(found).toBeDefined();
    expect(found!.text).toBe(content);
  });

  test("finds AGENTS.md in cwd as project scope", async () => {
    const content = "# Agents file";
    await writeFile(join(tmpCwd, "AGENTS.md"), content, "utf-8");

    const ctx = await discoverProjectContext(tmpCwd);
    const found = ctx.files.find((f) => f.path === join(tmpCwd, "AGENTS.md"));
    expect(found).toBeDefined();
    expect(found!.scope).toBe("project");
  });

  test("finds ancestor CLAUDE.md as ancestor scope", async () => {
    // Create a subdirectory as cwd.
    const subCwd = await mkdtemp(join(tmpCwd, "sub-"));

    // Write CLAUDE.md in the parent (tmpCwd).
    const content = "# Parent project notes";
    await writeFile(join(tmpCwd, "CLAUDE.md"), content, "utf-8");

    const ctx = await discoverProjectContext(subCwd);
    const found = ctx.files.find((f) => f.path === join(tmpCwd, "CLAUDE.md"));
    expect(found).toBeDefined();
    expect(found!.scope).toBe("ancestor");

    await rm(subCwd, { recursive: true, force: true });
  });

  test("finds ancestor CLAUDE.md up to git root only", async () => {
    // Simulate a git repo rooted at tmpCwd by creating a .git dir.
    await mkdir(join(tmpCwd, ".git"), { recursive: true });

    // Create a project subdirectory.
    const subCwd = join(tmpCwd, "packages", "mylib");
    await mkdir(subCwd, { recursive: true });

    // Write CLAUDE.md at the git root.
    await writeFile(join(tmpCwd, "CLAUDE.md"), "# Root", "utf-8");

    const ctx = await discoverProjectContext(subCwd);
    const found = ctx.files.find((f) => f.path === join(tmpCwd, "CLAUDE.md"));
    expect(found).toBeDefined();
    expect(found!.scope).toBe("ancestor");
  });

  test("user CLAUDE.md in ~/.cmux101/CLAUDE.md is user scope", async () => {
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    const content = "# User global notes";
    await writeFile(join(userDir, "CLAUDE.md"), content, "utf-8");

    const ctx = await discoverProjectContext(tmpCwd);
    const found = ctx.files.find((f) => f.scope === "user");
    expect(found).toBeDefined();
    expect(found!.text).toBe(content);
  });

  test("caps file size at 32 KB and appends truncation marker", async () => {
    // Create a file bigger than 32 KB.
    const bigContent = "x".repeat(40 * 1024);
    await writeFile(join(tmpCwd, "CLAUDE.md"), bigContent, "utf-8");

    const ctx = await discoverProjectContext(tmpCwd);
    const found = ctx.files.find((f) => f.path === join(tmpCwd, "CLAUDE.md"));
    expect(found).toBeDefined();
    expect(found!.text.endsWith("(truncated)")).toBe(true);
    expect(Buffer.byteLength(found!.text, "utf-8")).toBeLessThanOrEqual(32 * 1024 + 50);
  });

  test("caps total context at 128 KB, dropping lower-priority files first", async () => {
    // User file: large (60 KB)
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    const userContent = "u".repeat(60 * 1024);
    await writeFile(join(userDir, "CLAUDE.md"), userContent, "utf-8");

    // Ancestor file: large (50 KB) — create a parent dir with CLAUDE.md.
    const parentDir = await mkdtemp(join(tmpdir(), "cmux101-ancestor-"));
    const ancestorContent = "a".repeat(50 * 1024);
    await writeFile(join(parentDir, "CLAUDE.md"), ancestorContent, "utf-8");

    // Project file (cwd): 30 KB.
    const projectContent = "p".repeat(30 * 1024);
    await writeFile(join(tmpCwd, "CLAUDE.md"), projectContent, "utf-8");

    // Make tmpCwd a subdir of parentDir so the ancestor is found.
    const subCwd = join(parentDir, "child");
    await mkdir(subCwd, { recursive: true });
    await writeFile(join(subCwd, "CLAUDE.md"), projectContent, "utf-8");

    const ctx = await discoverProjectContext(subCwd);

    // Total bytes should be <= 128 KB.
    const total = ctx.files.reduce(
      (s, f) => s + Buffer.byteLength(f.text, "utf-8"),
      0
    );
    expect(total).toBeLessThanOrEqual(128 * 1024);

    // The project file should still be present (highest priority).
    const projectFound = ctx.files.find((f) => f.scope === "project");
    expect(projectFound).toBeDefined();

    await rm(parentDir, { recursive: true, force: true });
  });
});

describe("renderProjectContext", () => {
  test("returns empty string for empty context", () => {
    expect(renderProjectContext({ files: [] })).toBe("");
  });

  test("wraps content in <project-context> tags", () => {
    const ctx = {
      files: [
        { path: "/project/CLAUDE.md", text: "hello", scope: "project" as const },
      ],
    };
    const rendered = renderProjectContext(ctx);
    expect(rendered.startsWith("<project-context>")).toBe(true);
    expect(rendered.endsWith("</project-context>")).toBe(true);
    expect(rendered).toContain("## From /project/CLAUDE.md (project)");
    expect(rendered).toContain("hello");
  });
});
