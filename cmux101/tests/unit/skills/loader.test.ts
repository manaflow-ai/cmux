import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import { loadSkills, SkillRegistry } from "../../../src/skills/index";

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cmux101-skills-test-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function writeFile(filePath: string, content: string): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await Bun.write(filePath, content);
}

async function makeRegistry(dirs: string[]): Promise<SkillRegistry> {
  return loadSkills({ dirs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("skills loader", () => {
  test("loads a markdown skill with frontmatter parsed correctly", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(
      path.join(skillsDir, "review.md"),
      `---
name: review
description: Review the current diff
allowed_tools:
  - shell
  - file_read
---
Please review the diff:

{{args}}`
    );

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("review");

    expect(skill).toBeDefined();
    expect(skill!.name).toBe("review");
    expect(skill!.description).toBe("Review the current diff");
    expect(skill!.allowedTools).toEqual(["shell", "file_read"]);
    expect(skill!.body).toContain("Please review the diff:");
    expect(skill!.body).toContain("{{args}}");
    expect(skill!.shell).toBeUndefined();
  });

  test("loads a shell skill (*.sh with exec bit)", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    const scriptPath = path.join(skillsDir, "greet.sh");
    await writeFile(scriptPath, "#!/bin/sh\n# desc: Say hello\necho hello $1\n");
    await fs.chmod(scriptPath, 0o755);

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("greet");

    expect(skill).toBeDefined();
    expect(skill!.name).toBe("greet");
    expect(skill!.description).toBe("Say hello");
    expect(skill!.shell).toBe(scriptPath);
  });

  test("render substitutes {{args}} in markdown skill", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(
      path.join(skillsDir, "echo.md"),
      `---
name: echo
description: Echo args
---
The input is: {{args}}`
    );

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("echo")!;
    const rendered = await registry.render(skill, "hello world");

    expect(rendered).toBe("The input is: hello world");
  });

  test("render substitutes {{$ARGUMENTS}} in markdown skill", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(
      path.join(skillsDir, "argtest.md"),
      `---
name: argtest
description: Test ARGUMENTS substitution
---
Args: {{$ARGUMENTS}}`
    );

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("argtest")!;
    const rendered = await registry.render(skill, "foo bar");

    expect(rendered).toBe("Args: foo bar");
  });

  test("render executes shell skill and returns stdout", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    const scriptPath = path.join(skillsDir, "shout.sh");
    await writeFile(scriptPath, "#!/bin/sh\n# desc: Shout args\necho hello $1\n");
    await fs.chmod(scriptPath, 0o755);

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("shout")!;
    const rendered = await registry.render(skill, "world");

    expect(rendered.trim()).toBe("hello world");
  });

  test("name conflict: later dir wins", async () => {
    const dir1 = path.join(tmpDir, "dir1");
    const dir2 = path.join(tmpDir, "dir2");
    await fs.mkdir(dir1, { recursive: true });
    await fs.mkdir(dir2, { recursive: true });

    await writeFile(
      path.join(dir1, "myskill.md"),
      `---
name: myskill
description: From dir1
---
body from dir1`
    );

    await writeFile(
      path.join(dir2, "myskill.md"),
      `---
name: myskill
description: From dir2
---
body from dir2`
    );

    // dir2 is second — it should win
    const registry = await makeRegistry([dir1, dir2]);
    const skill = registry.get("myskill");

    expect(skill).toBeDefined();
    expect(skill!.description).toBe("From dir2");
    expect(skill!.body.trim()).toBe("body from dir2");
  });

  test("malformed frontmatter falls back to filename as name", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    // Missing closing --- so frontmatter is not parsed
    await writeFile(
      path.join(skillsDir, "fallback.md"),
      `---
name: broken
description: this has no closing delimiter
body goes here
`
    );

    const registry = await makeRegistry([skillsDir]);

    // When there's no closing ---, the whole file is treated as body with no frontmatter,
    // so the name comes from the filename "fallback"
    const skill = registry.get("fallback");
    expect(skill).toBeDefined();
    expect(skill!.name).toBe("fallback");
  });

  test("skills with invalid names are skipped with a warning", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    // Uppercase letter in name — invalid
    await writeFile(
      path.join(skillsDir, "Bad Name.md"),
      `---
name: Bad Name
description: Invalid name
---
body`
    );

    const registry = await makeRegistry([skillsDir]);
    // "Bad Name" (from frontmatter) is invalid; filename "Bad Name" is also invalid — both skipped
    const skills = registry.list();
    const bad = skills.find((s) => s.name.toLowerCase().includes("bad"));
    expect(bad).toBeUndefined();
  });

  test("list() returns all loaded skills", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(path.join(skillsDir, "alpha.md"), "---\nname: alpha\ndescription: A\n---\nbody a");
    await writeFile(path.join(skillsDir, "beta.md"), "---\nname: beta\ndescription: B\n---\nbody b");

    const registry = await makeRegistry([skillsDir]);
    const names = registry.list().map((s) => s.name).sort();
    expect(names).toEqual(["alpha", "beta"]);
  });

  test("non-existent directory is silently skipped", async () => {
    const nonExistent = path.join(tmpDir, "does-not-exist");
    const registry = await makeRegistry([nonExistent]);
    expect(registry.list()).toEqual([]);
  });

  test("markdown skill without frontmatter uses filename as name", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(
      path.join(skillsDir, "simple.md"),
      "Just a plain markdown file with no frontmatter.\n\nDo something useful.\n"
    );

    const registry = await makeRegistry([skillsDir]);
    const skill = registry.get("simple");

    expect(skill).toBeDefined();
    expect(skill!.name).toBe("simple");
    expect(skill!.body).toContain("Do something useful.");
  });

  test("frontmatter name overrides filename", async () => {
    const skillsDir = path.join(tmpDir, "skills");
    await fs.mkdir(skillsDir, { recursive: true });

    await writeFile(
      path.join(skillsDir, "filename-here.md"),
      `---
name: frontmatter-name
description: Uses frontmatter name
---
body`
    );

    const registry = await makeRegistry([skillsDir]);
    expect(registry.get("frontmatter-name")).toBeDefined();
    expect(registry.get("filename-here")).toBeUndefined();
  });
});
