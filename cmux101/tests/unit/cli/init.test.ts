import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, readFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInit } from "@/cli/init";

let tmpCwd: string;

beforeEach(async () => {
  tmpCwd = await mkdtemp(join(tmpdir(), "cmux101-init-"));
});

afterEach(async () => {
  await rm(tmpCwd, { recursive: true, force: true });
});

describe("runInit", () => {
  test("creates expected files on a fresh directory", async () => {
    const result = await runInit({ cwd: tmpCwd });

    // CLAUDE.md
    const claudeMdPath = join(tmpCwd, "CLAUDE.md");
    expect(existsSync(claudeMdPath)).toBe(true);
    const claudeContent = await readFile(claudeMdPath, "utf-8");
    expect(claudeContent).toContain("agent notes");
    expect(claudeContent).toContain("How to work in this repo");

    // .cmux101/config.json
    const configPath = join(tmpCwd, ".cmux101", "config.json");
    expect(existsSync(configPath)).toBe(true);
    const config = JSON.parse(await readFile(configPath, "utf-8"));
    expect(config.defaultModel).toBe("sonnet");
    expect(config.permissions.allow).toContain("file_read");
    expect(config.permissions.ask).toContain("shell");

    // .cmux101/skills/ and .cmux101/sessions/ directories
    expect(existsSync(join(tmpCwd, ".cmux101", "skills"))).toBe(true);
    expect(existsSync(join(tmpCwd, ".cmux101", "sessions"))).toBe(true);

    // .gitignore created and contains the entries
    const gitignorePath = join(tmpCwd, ".gitignore");
    expect(existsSync(gitignorePath)).toBe(true);
    const gitignoreContent = await readFile(gitignorePath, "utf-8");
    expect(gitignoreContent).toContain(".cmux101/sessions/");
    expect(gitignoreContent).toContain(".cmux101/memory/");
    expect(gitignoreContent).toContain(".cmux101/credentials.json");

    // created list includes the main files
    expect(result.created).toContain(claudeMdPath);
    expect(result.created).toContain(configPath);
  });

  test("is idempotent — second run reports files as skipped", async () => {
    await runInit({ cwd: tmpCwd });
    const result2 = await runInit({ cwd: tmpCwd });

    const claudeMdPath = join(tmpCwd, "CLAUDE.md");
    const configPath = join(tmpCwd, ".cmux101", "config.json");

    expect(result2.skipped).toContain(claudeMdPath);
    expect(result2.skipped).toContain(configPath);
    expect(result2.created).not.toContain(claudeMdPath);
    expect(result2.created).not.toContain(configPath);
  });

  test("--force overwrites existing files", async () => {
    // First run
    await runInit({ cwd: tmpCwd });

    // Modify CLAUDE.md
    const claudeMdPath = join(tmpCwd, "CLAUDE.md");
    await Bun.write(claudeMdPath, "# custom content");

    // Force run
    const result = await runInit({ cwd: tmpCwd, force: true });

    // CLAUDE.md should be in created (overwritten)
    expect(result.created).toContain(claudeMdPath);

    // Content should be reset to template
    const content = await readFile(claudeMdPath, "utf-8");
    expect(content).toContain("agent notes");
    expect(content).not.toBe("# custom content");
  });

  test("gitignore appends correctly when file already has content", async () => {
    const gitignorePath = join(tmpCwd, ".gitignore");
    await Bun.write(gitignorePath, "node_modules/\ndist/\n");

    await runInit({ cwd: tmpCwd });

    const content = await readFile(gitignorePath, "utf-8");
    // Original lines preserved
    expect(content).toContain("node_modules/");
    expect(content).toContain("dist/");
    // New lines appended
    expect(content).toContain(".cmux101/sessions/");
    expect(content).toContain(".cmux101/memory/");
    expect(content).toContain(".cmux101/credentials.json");
  });

  test("gitignore does not duplicate entries on second run", async () => {
    await runInit({ cwd: tmpCwd });
    await runInit({ cwd: tmpCwd });

    const gitignorePath = join(tmpCwd, ".gitignore");
    const content = await readFile(gitignorePath, "utf-8");

    // Count occurrences
    const sessionCount = (content.match(/\.cmux101\/sessions\//g) ?? []).length;
    const memoryCount = (content.match(/\.cmux101\/memory\//g) ?? []).length;
    const credCount = (content.match(/\.cmux101\/credentials\.json/g) ?? []).length;

    expect(sessionCount).toBe(1);
    expect(memoryCount).toBe(1);
    expect(credCount).toBe(1);
  });

  test("gitignore is skipped (not updated) on second run when entries already present", async () => {
    const result1 = await runInit({ cwd: tmpCwd });
    const result2 = await runInit({ cwd: tmpCwd });

    const gitignorePath = join(tmpCwd, ".gitignore");
    // First run: updated (was created or appended to)
    const firstRunTouched =
      result1.created.includes(gitignorePath) ||
      result1.updated.includes(gitignorePath);
    expect(firstRunTouched).toBe(true);

    // Second run: skipped (no duplicates needed)
    expect(result2.skipped).toContain(gitignorePath);
  });

  test("project name in CLAUDE.md matches directory basename", async () => {
    const result = await runInit({ cwd: tmpCwd });
    const claudeMdPath = join(tmpCwd, "CLAUDE.md");
    const content = await readFile(claudeMdPath, "utf-8");
    const basename = tmpCwd.split("/").pop()!;
    expect(content).toContain(basename);
  });

  test("config.json has correct permission structure", async () => {
    await runInit({ cwd: tmpCwd });
    const configPath = join(tmpCwd, ".cmux101", "config.json");
    const config = JSON.parse(await readFile(configPath, "utf-8"));

    expect(config.permissions.allow).toBeInstanceOf(Array);
    expect(config.permissions.ask).toBeInstanceOf(Array);
    expect(config.permissions.deny).toBeInstanceOf(Array);
    expect(config.permissions.allow).toContain("glob");
    expect(config.permissions.allow).toContain("grep");
    expect(config.permissions.ask).toContain("file_write");
    expect(config.permissions.ask).toContain("file_edit");
  });
});
