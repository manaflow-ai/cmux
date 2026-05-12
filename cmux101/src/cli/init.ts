/**
 * cmux101 init — bootstraps a project with CLAUDE.md, .cmux101/ config,
 * and sensible .gitignore entries.
 */

import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile, appendFile } from "node:fs/promises";
import { basename, join } from "node:path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface InitResult {
  created: string[];
  skipped: string[];
  updated: string[];
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

function claudeMdTemplate(projectName: string): string {
  return `# ${projectName} — agent notes

## How to work in this repo
- Build: \`<TODO>\`
- Test: \`<TODO>\`
- Lint: \`<TODO>\`

## Conventions
- <TODO: any project-wide constraints the agent should know>

## Pitfalls
- <TODO>
`;
}

const CONFIG_JSON = JSON.stringify(
  {
    defaultModel: "sonnet",
    permissions: {
      allow: ["file_read", "glob", "grep", "web_fetch", "web_search"],
      ask: ["shell", "file_write", "file_edit"],
      deny: [],
    },
  },
  null,
  2
) + "\n";

const GITIGNORE_LINES = `.cmux101/sessions/\n.cmux101/memory/\n.cmux101/credentials.json\n`;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

export async function runInit(opts: {
  cwd: string;
  force?: boolean;
}): Promise<InitResult> {
  const { cwd, force = false } = opts;
  const projectName = basename(cwd);
  const result: InitResult = { created: [], skipped: [], updated: [] };

  // Helper: write a file idempotently.
  async function writeIdempotent(filePath: string, content: string): Promise<void> {
    if (existsSync(filePath) && !force) {
      result.skipped.push(filePath);
      return;
    }
    await writeFile(filePath, content, { encoding: "utf-8" });
    if (existsSync(filePath) && force) {
      result.created.push(filePath); // overwritten counts as created when forced
    } else {
      result.created.push(filePath);
    }
  }

  // Helper: ensure directory exists.
  async function ensureDir(dirPath: string): Promise<void> {
    await mkdir(dirPath, { recursive: true });
  }

  // ── 1. CLAUDE.md ──────────────────────────────────────────────────────────
  const claudeMdPath = join(cwd, "CLAUDE.md");
  await writeIdempotent(claudeMdPath, claudeMdTemplate(projectName));

  // ── 2. .cmux101/config.json ───────────────────────────────────────────────
  const cmux101Dir = join(cwd, ".cmux101");
  await ensureDir(cmux101Dir);
  const configPath = join(cmux101Dir, "config.json");
  await writeIdempotent(configPath, CONFIG_JSON);

  // ── 3. .cmux101/skills/ (empty dir) ──────────────────────────────────────
  const skillsDir = join(cmux101Dir, "skills");
  await ensureDir(skillsDir);
  // Track it if freshly made — mkdir is idempotent so we just record it.
  if (!result.created.includes(skillsDir) && !result.skipped.includes(skillsDir)) {
    result.created.push(skillsDir);
  }

  // ── 4. .cmux101/sessions/ (empty dir) ────────────────────────────────────
  const sessionsDir = join(cmux101Dir, "sessions");
  await ensureDir(sessionsDir);
  if (!result.created.includes(sessionsDir) && !result.skipped.includes(sessionsDir)) {
    result.created.push(sessionsDir);
  }

  // ── 5. .gitignore ─────────────────────────────────────────────────────────
  const gitignorePath = join(cwd, ".gitignore");
  await patchGitignore(gitignorePath, result);

  return result;
}

// ---------------------------------------------------------------------------
// .gitignore patching
// ---------------------------------------------------------------------------

const GITIGNORE_ENTRIES = [
  ".cmux101/sessions/",
  ".cmux101/memory/",
  ".cmux101/credentials.json",
];

async function patchGitignore(
  gitignorePath: string,
  result: InitResult
): Promise<void> {
  let existing = "";
  if (existsSync(gitignorePath)) {
    existing = await readFile(gitignorePath, { encoding: "utf-8" });
  }

  const lines = existing.split("\n");
  const missing = GITIGNORE_ENTRIES.filter((entry) => !lines.includes(entry));

  if (missing.length === 0) {
    // Already fully present — nothing to do.
    result.skipped.push(gitignorePath);
    return;
  }

  // Append missing entries.
  const toAppend = missing.map((e) => e + "\n").join("");
  // Ensure there's a trailing newline before our block if file is non-empty.
  const needsNewline = existing.length > 0 && !existing.endsWith("\n");
  await appendFile(gitignorePath, (needsNewline ? "\n" : "") + toAppend, {
    encoding: "utf-8",
  });

  result.updated.push(gitignorePath);
}
