import { agentKey } from "../shared/AgentMark";

// Display names for agent harnesses. acpmux names a harness by its config id
// ("codex", "claude-sr"), which is not what the agent is called.

const KNOWN: Record<string, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
  opencode: "OpenCode",
  cursor: "Cursor",
  pi: "Pi",
  goose: "Goose",
  amp: "Amp",
  qwen: "Qwen Code",
  copilot: "GitHub Copilot",
  aider: "Aider",
};

/// The agent's name for a harness id. Variants share their agent's name ("claude-sr" is
/// Claude Code); an unknown id is title-cased ("my-agent" is "My Agent").
export function agentDisplayName(id: string): string {
  const words = id.split(/[-_\s]+/).filter(Boolean);
  const known = KNOWN[agentKey(id) ?? ""];
  if (known) return known;
  return words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ") || id;
}

/// The catalog's name when the daemon gave a real one, else the display name for the id.
export function agentName(id: string, name?: string): string {
  return name && name !== id ? name : agentDisplayName(id);
}
