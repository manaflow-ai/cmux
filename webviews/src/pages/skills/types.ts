export type SkillKind = "skill" | "mcp" | "plugin";
export type Harness = "claude" | "codex" | "pi" | "opencode";

export interface DirectoryEntry {
  id: string;
  kind: SkillKind;
  name: string;
  description: string;
  publisher: string;
  version: string;
  targets: Harness[];
  installed: Partial<Record<Harness, boolean>>;
}

export interface DirectoryResult {
  schemaVersion: number;
  entries: DirectoryEntry[];
}

export const SkillsOps = {
  list: "skills.directory.list",
  install: "skills.directory.install",
  remove: "skills.directory.remove",
  status: "skills.directory.status",
} as const;
