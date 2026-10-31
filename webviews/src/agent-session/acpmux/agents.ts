import { agentKey } from "../shared/agentKey";

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
  // acpmux's built-in Chief harness (`cmux chief acp`): the person's chat with their Chief.
  chief: "Chief",
};

/// The agent's name for a harness id. Variants share their agent's name ("claude-sr" is
/// Claude Code); an unknown id is title-cased ("my-agent" is "My Agent").
export function agentDisplayName(id: string): string {
  const words = id.split(/[-_\s]+/).filter(Boolean);
  const key = agentKey(id);
  const known = key && Object.hasOwn(KNOWN, key) ? KNOWN[key] : undefined;
  if (known) return known;
  return words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ") || id;
}

/// The catalog's name when the daemon gave a real one, else the display name for the id.
export function agentName(id: string, name?: string): string {
  return name && name !== id ? name : agentDisplayName(id);
}

/// The model chip's label when the chat's harness offers no models at all (its catalog row and
/// its session list none): the harness's own name, so a chat on the Chief (which picks its own
/// engine) reads "Chief", not a "Model" chip with nothing to pick. Undefined while any model is
/// known: the chip then names the model as usual.
export function modelChipFallback(
  entry: { id: string; name?: string; models: readonly unknown[] } | undefined,
  sessionModels: readonly unknown[],
): string | undefined {
  if (!entry || entry.models.length > 0 || sessionModels.length > 0) return undefined;
  return agentName(entry.id, entry.name);
}
