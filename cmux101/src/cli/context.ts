/**
 * Project context loader — reads CLAUDE.md / AGENTS.md files from the
 * directory tree and formats them as a <project-context> block for the
 * system prompt.  Matches Claude Code / claw-code discovery behavior.
 */

import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ProjectContextFile {
  path: string;
  text: string;
  scope: "user" | "project" | "ancestor";
}

export interface ProjectContext {
  files: Array<ProjectContextFile>;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const FILE_SIZE_CAP = 32 * 1024; // 32 KB per file
const TOTAL_CAP = 128 * 1024;    // 128 KB total

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Read a file, capping at FILE_SIZE_CAP bytes. */
async function readCapped(filePath: string): Promise<string | null> {
  try {
    const raw = await readFile(filePath, { encoding: "utf-8", flag: "r" });
    if (Buffer.byteLength(raw, "utf-8") > FILE_SIZE_CAP) {
      // Truncate at byte boundary (safe because we're dealing with UTF-8 slices).
      const truncated = raw.slice(0, FILE_SIZE_CAP);
      return truncated + "\n\n(truncated)";
    }
    return raw;
  } catch {
    return null;
  }
}

/** Try to find the git root by walking upward. Returns null if not found. */
function findGitRoot(startDir: string): string | null {
  let cur = startDir;
  while (true) {
    if (existsSync(join(cur, ".git"))) return cur;
    const parent = dirname(cur);
    if (parent === cur) return null; // filesystem root
    cur = parent;
  }
}

/** Collect ancestor directories from cwd up to git root (or fs root). */
function collectAncestors(cwd: string): string[] {
  const gitRoot = findGitRoot(cwd);
  const dirs: string[] = [];
  let cur = dirname(cwd); // start above cwd so we don't double-include it
  while (true) {
    dirs.push(cur);
    if (gitRoot && cur === gitRoot) break;
    const parent = dirname(cur);
    if (parent === cur) break; // fs root
    cur = parent;
  }
  return dirs;
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export async function discoverProjectContext(cwd: string): Promise<ProjectContext> {
  const absoCwd = resolve(cwd);
  const files: ProjectContextFile[] = [];

  // ── 1. User-scope files ──────────────────────────────────────────────────
  // Use process.env.HOME rather than homedir() so that tests can override HOME.
  const home = process.env.HOME ?? process.env.USERPROFILE ?? "~";
  const userPaths = [
    join(home, ".cmux101", "CLAUDE.md"),
    join(home, "CLAUDE.md"),
  ];
  for (const p of userPaths) {
    const text = await readCapped(p);
    if (text !== null) {
      files.push({ path: p, text, scope: "user" });
    }
  }

  // ── 2. Ancestor CLAUDE.md files (from cwd upward, excluding cwd itself) ──
  const ancestorDirs = collectAncestors(absoCwd);
  for (const dir of ancestorDirs) {
    const p = join(dir, "CLAUDE.md");
    const text = await readCapped(p);
    if (text !== null) {
      files.push({ path: p, text, scope: "ancestor" });
    }
  }

  // ── 3. Project-scope files (cwd) ─────────────────────────────────────────
  const projectCandidates = [
    join(absoCwd, "CLAUDE.md"),
    join(absoCwd, "AGENTS.md"),
    join(absoCwd, ".cmux101", "CLAUDE.md"),
  ];
  for (const p of projectCandidates) {
    const text = await readCapped(p);
    if (text !== null) {
      files.push({ path: p, text, scope: "project" });
    }
  }

  // ── 4. Cap total context ─────────────────────────────────────────────────
  // Priority: project > ancestor > user.  Drop lowest-priority files first.
  const priorityOrder: Array<ProjectContextFile["scope"]> = ["user", "ancestor", "project"];

  let totalBytes = files.reduce((s, f) => s + Buffer.byteLength(f.text, "utf-8"), 0);

  if (totalBytes > TOTAL_CAP) {
    // Work through priority order (drop user first, then ancestor, then project).
    for (const scope of priorityOrder) {
      if (totalBytes <= TOTAL_CAP) break;
      // Find files of this scope (in reverse insertion order so we drop latest first).
      const indices = files
        .map((f, i) => ({ f, i }))
        .filter(({ f }) => f.scope === scope)
        .map(({ i }) => i)
        .reverse();

      for (const idx of indices) {
        if (totalBytes <= TOTAL_CAP) break;
        totalBytes -= Buffer.byteLength(files[idx]!.text, "utf-8");
        files.splice(idx, 1);
      }
    }
  }

  return { files };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

export function renderProjectContext(ctx: ProjectContext): string {
  if (ctx.files.length === 0) return "";

  const sections = ctx.files.map((f) => {
    const label = scopeLabel(f.path, f.scope);
    return `## From ${label}\n${f.text}`;
  });

  return `<project-context>\n${sections.join("\n\n")}\n</project-context>`;
}

function scopeLabel(filePath: string, scope: ProjectContextFile["scope"]): string {
  return `${filePath} (${scope})`;
}
