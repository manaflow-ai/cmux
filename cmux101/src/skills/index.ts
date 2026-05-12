/**
 * Skills loader for cmux101.
 *
 * Skills are reusable prompt templates invoked as `/skillname args`.
 * Two formats are supported:
 *   A) Markdown with optional YAML frontmatter (*.md)
 *   B) Executable shell scripts (*.sh or any file with shebang + exec bit)
 */

import type { Skill } from "../core/types";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import { spawnSync } from "node:child_process";

// ---------------------------------------------------------------------------
// Name validation
// ---------------------------------------------------------------------------

const NAME_RE = /^[a-z0-9_-]+$/;

function isValidName(name: string): boolean {
  return NAME_RE.test(name);
}

// ---------------------------------------------------------------------------
// Tiny YAML subset parser
// Handles: `key: value` strings and `- item` lists under a key.
// ---------------------------------------------------------------------------

interface ParsedFrontmatter {
  name?: string;
  description?: string;
  allowed_tools?: string[];
}

function parseFrontmatter(raw: string): ParsedFrontmatter {
  const result: ParsedFrontmatter = {};
  const lines = raw.split("\n");

  let currentKey: string | null = null;
  let currentList: string[] | null = null;

  for (const line of lines) {
    // List item under current key
    if (currentList !== null && line.match(/^\s*-\s+/)) {
      const item = line.replace(/^\s*-\s+/, "").trim();
      if (item) currentList.push(item);
      continue;
    }

    // Key: value line
    const kvMatch = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$/);
    if (kvMatch) {
      // Flush any in-progress list
      if (currentKey !== null && currentList !== null) {
        (result as Record<string, unknown>)[currentKey] = currentList;
      }
      currentKey = kvMatch[1]!;
      const value = kvMatch[2]!.trim();

      if (value === "" || value === "|" || value === ">") {
        // Value will come as list items
        currentList = [];
      } else {
        currentList = null;
        (result as Record<string, unknown>)[currentKey] = value;
        currentKey = null;
      }
      continue;
    }

    // Blank line or unrecognised — flush list if any
    if (currentKey !== null && currentList !== null) {
      (result as Record<string, unknown>)[currentKey] = currentList;
      currentKey = null;
      currentList = null;
    }
  }

  // Flush trailing list
  if (currentKey !== null && currentList !== null) {
    (result as Record<string, unknown>)[currentKey] = currentList;
  }

  return result;
}

// ---------------------------------------------------------------------------
// File parsing helpers
// ---------------------------------------------------------------------------

function parseMarkdownSkill(filePath: string, raw: string): Skill | null {
  let frontmatter: ParsedFrontmatter = {};
  let body = raw;

  // Detect YAML frontmatter block (starts with ---)
  if (raw.startsWith("---")) {
    const end = raw.indexOf("\n---", 3);
    if (end !== -1) {
      const fmRaw = raw.slice(3, end).trim();
      const afterFm = raw.slice(end + 4); // skip closing ---
      body = afterFm.replace(/^\n/, "");
      try {
        frontmatter = parseFrontmatter(fmRaw);
      } catch {
        // malformed — fall back to filename-derived name
        frontmatter = {};
      }
    }
    // If no closing ---, treat whole file as body with no frontmatter
  }

  const basename = path.basename(filePath, path.extname(filePath));
  const name = (frontmatter.name ?? basename).trim();

  if (!isValidName(name)) {
    console.warn(`[skills] Skipping skill with invalid name: "${name}" (from ${filePath})`);
    return null;
  }

  const description = frontmatter.description ?? "";
  const allowedTools = Array.isArray(frontmatter.allowed_tools)
    ? frontmatter.allowed_tools
    : undefined;

  return {
    name,
    description,
    body,
    allowedTools,
  };
}

function parseShellSkill(filePath: string): Skill {
  const basename = path.basename(filePath);
  const name = basename.replace(/\.[^.]+$/, ""); // strip extension
  let description = "";

  // Read first comment line for description (# desc: ...)
  try {
    const content = require("node:fs").readFileSync(filePath, "utf8") as string;
    const firstComment = content
      .split("\n")
      .find((l: string) => l.startsWith("#") && !l.startsWith("#!"));
    if (firstComment) {
      // Support both "# desc: ..." and plain "# ..." forms
      const descMatch = firstComment.match(/^#\s*(?:desc:\s*)?(.*)/);
      if (descMatch) description = descMatch[1]!.trim();
    }
  } catch {
    // ignore read errors — description stays empty
  }

  return {
    name,
    description,
    body: "",
    shell: filePath,
  };
}

// ---------------------------------------------------------------------------
// isExecutable helper
// ---------------------------------------------------------------------------

async function isExecutable(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function hasShebang(filePath: string): boolean {
  try {
    const buf = Buffer.alloc(2);
    const fd = require("node:fs").openSync(filePath, "r");
    require("node:fs").readSync(fd, buf, 0, 2, 0);
    require("node:fs").closeSync(fd);
    return buf[0] === 0x23 && buf[1] === 0x21; // #!
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Load a single file into a Skill (or null if invalid/unsupported)
// ---------------------------------------------------------------------------

async function loadFile(filePath: string): Promise<Skill | null> {
  const ext = path.extname(filePath).toLowerCase();

  if (ext === ".md") {
    let raw: string;
    try {
      raw = await Bun.file(filePath).text();
    } catch {
      return null;
    }
    return parseMarkdownSkill(filePath, raw);
  }

  // Shell skill: *.sh or executable with shebang
  if (ext === ".sh" || (await isExecutable(filePath) && hasShebang(filePath))) {
    const skill = parseShellSkill(filePath);
    if (!isValidName(skill.name)) {
      console.warn(`[skills] Skipping shell skill with invalid name: "${skill.name}" (from ${filePath})`);
      return null;
    }
    return skill;
  }

  return null;
}

// ---------------------------------------------------------------------------
// SkillRegistry
// ---------------------------------------------------------------------------

export class SkillRegistry {
  private readonly _skills: Map<string, Skill>;

  constructor(skills: Map<string, Skill>) {
    this._skills = skills;
  }

  list(): Skill[] {
    return Array.from(this._skills.values());
  }

  get(name: string): Skill | undefined {
    return this._skills.get(name);
  }

  async render(skill: Skill, args: string): Promise<string> {
    if (skill.shell) {
      // Execute shell script; pass args as argv[1]
      const result = spawnSync(skill.shell, [args], {
        timeout: 10_000,
        encoding: "utf8",
      });
      if (result.error) {
        throw new Error(`Skill "${skill.name}" execution failed: ${result.error.message}`);
      }
      return result.stdout ?? "";
    }

    // Template substitution
    return skill.body
      .replace(/\{\{args\}\}/g, args)
      .replace(/\{\{\$ARGUMENTS\}\}/g, args);
  }
}

// ---------------------------------------------------------------------------
// loadSkills
// ---------------------------------------------------------------------------

export async function loadSkills(opts: { dirs: string[] }): Promise<SkillRegistry> {
  const defaultDirs = [
    path.join(process.cwd(), ".cmux101", "skills"),
    path.join(os.homedir(), ".cmux101", "skills"),
  ];

  // Merge: default dirs first, then caller-supplied dirs (later wins)
  const allDirs = [...defaultDirs, ...opts.dirs];

  // Accumulated map; later entries overwrite earlier ones (last wins)
  const accumulated = new Map<string, Skill>();

  for (const dir of allDirs) {
    let entries: string[];
    try {
      const dirEntries = await fs.readdir(dir);
      entries = dirEntries;
    } catch {
      // Directory doesn't exist or isn't readable — skip silently
      continue;
    }

    for (const entry of entries) {
      const filePath = path.join(dir, entry);
      let stat: Awaited<ReturnType<typeof fs.stat>>;
      try {
        stat = await fs.stat(filePath);
      } catch {
        continue;
      }
      if (!stat.isFile()) continue;

      const skill = await loadFile(filePath);
      if (skill) {
        accumulated.set(skill.name, skill);
      }
    }
  }

  return new SkillRegistry(accumulated);
}
