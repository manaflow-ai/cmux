// Which files are agent memory, for which agents, and what kind. Paths are
// relative to a root handle: a "user" root (the home folder of a machine,
// shown as ~) or a "project" root (a workspace folder). The owner lists
// files; the app classifies them with this table so a new agent is one row.

export type RootKind = "user" | "project"
export type MemoryKind = "instructions" | "local" | "override" | "memoryIndex" | "memoryTopic" | "rules"

export type Classification = { agents: string[]; kind: MemoryKind; /** Claude project memory: the slug of the project it belongs to. */ slug?: string }

type Rule = { root: RootKind; pattern: RegExp; agents: string[]; kind: MemoryKind }

/** Agents that read AGENTS.md in a project or its subfolders. */
export const AGENTS_MD_READERS = ["codex", "opencode", "pi", "amp", "cursor"]

const RULES: Rule[] = [
  { root: "user", pattern: /^\.claude\/CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
  { root: "user", pattern: /^\.claude\/projects\/[^/]+\/memory\/MEMORY\.md$/, agents: ["claude"], kind: "memoryIndex" },
  { root: "user", pattern: /^\.claude\/projects\/[^/]+\/memory\/[^/]+\.md$/, agents: ["claude"], kind: "memoryTopic" },
  { root: "user", pattern: /^\.codex\/AGENTS\.md$/, agents: ["codex"], kind: "instructions" },
  { root: "user", pattern: /^\.codex\/AGENTS\.override\.md$/, agents: ["codex"], kind: "override" },
  { root: "user", pattern: /^\.config\/opencode\/AGENTS\.md$/, agents: ["opencode"], kind: "instructions" },
  { root: "user", pattern: /^\.gemini\/GEMINI\.md$/, agents: ["gemini"], kind: "instructions" },
  { root: "user", pattern: /^\.pi\/agent\/AGENTS\.md$/, agents: ["pi"], kind: "instructions" },
  { root: "project", pattern: /^(?:.+\/)?CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
  { root: "project", pattern: /^\.claude\/CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
  { root: "project", pattern: /^(?:.+\/)?CLAUDE\.local\.md$/, agents: ["claude"], kind: "local" },
  { root: "project", pattern: /^(?:.+\/)?AGENTS\.override\.md$/, agents: ["codex"], kind: "override" },
  { root: "project", pattern: /^(?:.+\/)?AGENTS\.md$/, agents: AGENTS_MD_READERS, kind: "instructions" },
  { root: "project", pattern: /^(?:.+\/)?GEMINI\.md$/, agents: ["gemini"], kind: "instructions" },
  { root: "project", pattern: /^\.github\/copilot-instructions\.md$/, agents: ["copilot"], kind: "instructions" },
  { root: "project", pattern: /^\.cursor\/rules\/[^/]+\.mdc?$/, agents: ["cursor"], kind: "rules" }
]

// More specific rules first: `.claude/CLAUDE.md` before `**/CLAUDE.md`, override before AGENTS.md.
export function classify(root: RootKind, path: string): Classification | null {
  if (path.split("/").some((p) => p === ".." || p === "")) return null
  for (const r of RULES) {
    if (r.root !== root || !r.pattern.test(path)) continue
    const slug = /^\.claude\/projects\/([^/]+)\/memory\//.exec(path)?.[1]
    return { agents: r.agents, kind: r.kind, ...(slug ? { slug } : {}) }
  }
  return null
}

/** Folder depth inside a project (0 = root): a nested AGENTS.md applies to its folder only. */
export const depthOf = (path: string) => path.split("/").length - 1

export const AGENT_NAMES: Record<string, string> = {
  claude: "Claude Code",
  codex: "Codex",
  opencode: "OpenCode",
  pi: "Pi",
  amp: "Amp",
  cursor: "Cursor",
  gemini: "Gemini CLI",
  copilot: "Copilot"
}

export const agentName = (id: string) => AGENT_NAMES[id] ?? id

/** "Codex, OpenCode +3": at most `max` names. */
export function agentsLabel(agents: readonly string[], max = 2): string {
  const names = agents.map(agentName)
  return names.length <= max ? names.join(", ") : `${names.slice(0, max).join(", ")} +${names.length - max}`
}

/** Sort: project instructions at the root first, then nested, then user files, index before topics. */
export function fileRank(root: RootKind, path: string, c: Classification): number {
  const kindRank: Record<MemoryKind, number> = { instructions: 0, override: 1, local: 2, memoryIndex: 3, memoryTopic: 4, rules: 5 }
  return (root === "project" ? 0 : 100) + depthOf(path) * 10 + kindRank[c.kind]
}
