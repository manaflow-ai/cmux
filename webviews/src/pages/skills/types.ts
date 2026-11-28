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
  list: "cmux.skills.directory.list",
  install: "cmux.skills.directory.install",
  remove: "cmux.skills.directory.remove",
  status: "cmux.skills.directory.status",
} as const;
