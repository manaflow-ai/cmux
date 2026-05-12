import * as path from "node:path";
import * as fs from "node:fs/promises";
import type { Dirent } from "node:fs";
import { z } from "zod";
import type { Tool, ToolResult } from "../core/types";

// ----------------------------------------------------------------------------
// Types
// ----------------------------------------------------------------------------

export interface MemoryRecord {
  name: string;
  description: string;
  type: "user" | "feedback" | "project" | "reference";
  body: string;
  scope: "global" | "project";
  path: string;
}

// ----------------------------------------------------------------------------
// Frontmatter parser
// ----------------------------------------------------------------------------

interface ParsedFrontmatter {
  name: string;
  description: string;
  type: "user" | "feedback" | "project" | "reference";
  body: string;
}

const VALID_TYPES = new Set(["user", "feedback", "project", "reference"]);

function parseFrontmatter(raw: string, filePath: string): ParsedFrontmatter | null {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) {
    console.warn(`[memory] skipping ${filePath}: missing frontmatter delimiters`);
    return null;
  }

  const fmBlock = match[1];
  const body = match[2].trim();

  // Parse simple key: value and nested metadata.type
  let name = "";
  let description = "";
  let type = "";

  let inMetadata = false;
  for (const line of fmBlock.split("\n")) {
    const stripped = line.replace(/\r$/, "");

    if (stripped === "metadata:") {
      inMetadata = true;
      continue;
    }

    if (inMetadata) {
      const nested = stripped.match(/^\s{2}type:\s*(.+)$/);
      if (nested) {
        type = nested[1].trim();
        continue;
      }
      // If we hit a non-indented line, we're out of metadata
      if (stripped && !stripped.startsWith("  ")) {
        inMetadata = false;
      }
    }

    const nameMatch = stripped.match(/^name:\s*(.+)$/);
    if (nameMatch) { name = nameMatch[1].trim(); continue; }

    const descMatch = stripped.match(/^description:\s*(.+)$/);
    if (descMatch) { description = descMatch[1].trim(); continue; }
  }

  if (!name) {
    console.warn(`[memory] skipping ${filePath}: missing 'name' in frontmatter`);
    return null;
  }
  if (!description) {
    console.warn(`[memory] skipping ${filePath}: missing 'description' in frontmatter`);
    return null;
  }
  if (!VALID_TYPES.has(type)) {
    console.warn(`[memory] skipping ${filePath}: invalid or missing 'type' (got '${type}')`);
    return null;
  }

  return {
    name,
    description,
    type: type as MemoryRecord["type"],
    body,
  };
}

function serializeFrontmatter(record: Omit<MemoryRecord, "path">): string {
  return `---
name: ${record.name}
description: ${record.description}
metadata:
  type: ${record.type}
---

${record.body}
`;
}

// ----------------------------------------------------------------------------
// MemoryStore
// ----------------------------------------------------------------------------

export class MemoryStore {
  private globalDir: string;
  private projectDir: string | undefined;

  constructor(opts: { globalDir: string; projectDir?: string }) {
    this.globalDir = opts.globalDir;
    this.projectDir = opts.projectDir;
  }

  private scopeDir(scope: "global" | "project"): string {
    if (scope === "project") {
      if (!this.projectDir) throw new Error("No projectDir configured");
      return this.projectDir;
    }
    return this.globalDir;
  }

  private async readDir(dir: string, scope: "global" | "project"): Promise<MemoryRecord[]> {
    let entries: Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return [];
    }

    const records: MemoryRecord[] = [];
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith(".md")) continue;
      if (entry.name === "MEMORY.md") continue;

      const filePath = path.join(dir, entry.name);
      let raw: string;
      try {
        raw = await Bun.file(filePath).text();
      } catch {
        console.warn(`[memory] could not read ${filePath}`);
        continue;
      }

      const parsed = parseFrontmatter(raw, filePath);
      if (!parsed) continue;

      records.push({
        name: parsed.name,
        description: parsed.description,
        type: parsed.type,
        body: parsed.body,
        scope,
        path: filePath,
      });
    }

    return records;
  }

  async list(): Promise<MemoryRecord[]> {
    const globalRecords = await this.readDir(this.globalDir, "global");
    const projectRecords = this.projectDir
      ? await this.readDir(this.projectDir, "project")
      : [];
    return [...globalRecords, ...projectRecords];
  }

  async get(name: string): Promise<MemoryRecord | null> {
    const all = await this.list();
    return all.find((r) => r.name === name) ?? null;
  }

  async save(record: Omit<MemoryRecord, "path">): Promise<MemoryRecord> {
    const dir = this.scopeDir(record.scope);
    await fs.mkdir(dir, { recursive: true });

    const filePath = path.join(dir, `${record.name}.md`);
    const content = serializeFrontmatter(record);
    await Bun.write(filePath, content);

    await this.rebuildIndex(dir);

    return { ...record, path: filePath };
  }

  async remove(name: string): Promise<boolean> {
    // Try project first, then global
    const candidates: Array<{ dir: string; scope: "global" | "project" }> = [];
    if (this.projectDir) {
      candidates.push({ dir: this.projectDir, scope: "project" });
    }
    candidates.push({ dir: this.globalDir, scope: "global" });

    for (const { dir } of candidates) {
      const filePath = path.join(dir, `${name}.md`);
      try {
        await fs.unlink(filePath);
        await this.rebuildIndex(dir);
        return true;
      } catch {
        // file didn't exist in this dir, try next
      }
    }
    return false;
  }

  private async rebuildIndex(dir: string): Promise<void> {
    let entries: Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    const mdFiles = entries
      .filter((e) => e.isFile() && e.name.endsWith(".md") && e.name !== "MEMORY.md")
      .map((e) => e.name)
      .sort();

    const lines: string[] = ["# Memory index", ""];
    for (const fileName of mdFiles) {
      const filePath = path.join(dir, fileName);
      let raw: string;
      try {
        raw = await Bun.file(filePath).text();
      } catch {
        continue;
      }
      const parsed = parseFrontmatter(raw, filePath);
      if (!parsed) continue;
      lines.push(`- [${parsed.name}](${fileName}) — ${parsed.description}`);
    }

    const indexPath = path.join(dir, "MEMORY.md");
    await Bun.write(indexPath, lines.join("\n") + "\n");
  }

  async indexMarkdown(): Promise<string> {
    const parts: string[] = [];

    const globalIndex = path.join(this.globalDir, "MEMORY.md");
    try {
      parts.push(`## Global memories\n\n${await Bun.file(globalIndex).text()}`);
    } catch {
      parts.push("## Global memories\n\n(none)");
    }

    if (this.projectDir) {
      const projectIndex = path.join(this.projectDir, "MEMORY.md");
      try {
        parts.push(`## Project memories\n\n${await Bun.file(projectIndex).text()}`);
      } catch {
        parts.push("## Project memories\n\n(none)");
      }
    }

    return parts.join("\n\n");
  }
}

// ----------------------------------------------------------------------------
// Tools
// ----------------------------------------------------------------------------

export function buildMemoryTools(store: MemoryStore): Tool[] {
  const memoryListTool: Tool = {
    name: "memory_list",
    description: "List all memories (name, type, description) stored in global and project scopes.",
    inputSchema: z.object({}),
    defaultPermission: "allow" as const,
    async run(_input: unknown, _ctx: unknown): Promise<ToolResult> {
      const records = await store.list();
      if (records.length === 0) {
        return { content: "No memories stored." };
      }
      const lines = records.map(
        (r) => `[${r.scope}] ${r.name} (${r.type}): ${r.description}`
      );
      return { content: lines.join("\n") };
    },
  };

  const memorySaveTool: Tool = {
    name: "memory_save",
    description:
      "Save a memory to persistent storage. Use scope='global' for user/cross-project info, 'project' for project-specific info.",
    inputSchema: z.object({
      name: z.string().regex(/^[a-z0-9-]+$/, "name must be kebab-case"),
      description: z.string(),
      type: z.enum(["user", "feedback", "project", "reference"]),
      body: z.string(),
      scope: z.enum(["global", "project"]).optional().default("global"),
    }),
    defaultPermission: "allow" as const,
    async run(input: unknown, _ctx: unknown): Promise<ToolResult> {
      const schema = memorySaveTool.inputSchema as ReturnType<typeof z.object>;
      const parsed = schema.parse(input) as {
        name: string;
        description: string;
        type: MemoryRecord["type"];
        body: string;
        scope: "global" | "project";
      };

      const record = await store.save(parsed);
      return {
        content: `Saved memory '${record.name}' to ${record.scope} scope at ${record.path}`,
      };
    },
  };

  const memoryRemoveTool: Tool = {
    name: "memory_remove",
    description: "Remove a memory by name.",
    inputSchema: z.object({
      name: z.string(),
    }),
    defaultPermission: "allow" as const,
    async run(input: unknown, _ctx: unknown): Promise<ToolResult> {
      const schema = memoryRemoveTool.inputSchema as ReturnType<typeof z.object>;
      const parsed = schema.parse(input) as { name: string };
      const removed = await store.remove(parsed.name);
      if (removed) {
        return { content: `Removed memory '${parsed.name}'.` };
      }
      return { content: `Memory '${parsed.name}' not found.`, isError: true };
    },
  };

  return [memoryListTool, memorySaveTool, memoryRemoveTool];
}
