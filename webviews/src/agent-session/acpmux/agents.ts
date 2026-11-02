import { agentKey } from "../shared/agentKey";
import { isDefaultChoice } from "./defaultChoice";

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
/// its session list none, beyond acpmux's placeholder default): the harness's own name, so a chat on the Chief (which picks its own
/// engine) reads "Chief", not a "Model" chip with nothing to pick. Undefined while any model is
/// known: the chip then names the model as usual.
export function modelChipFallback(
  entry: { id: string; name?: string; models: readonly { id: string; name?: string }[] } | undefined,
  sessionModels: readonly { id: string; name?: string }[],
): string | undefined {
  // acpmux lists a harness that reports none with its agent's default only (`default (agent's
  // choice)`), which the picker never shows as a row: that is no model either.
  const real = (models: readonly { id: string; name?: string }[]) => models.some((m) => !isDefaultChoice(m));
  if (!entry || real(entry.models) || real(sessionModels)) return undefined;
  return agentName(entry.id, entry.name);
}

/// acpmux's family of its built-in Chief harness (`cmux chief acp`): the person's Chief, which
/// picks its own model, so its picker offers no model list, refresh or account.
export const CHIEF_FAMILY = "chief";

/// Whether a harness of `family` picks its own model (the Chief).
export function picksOwnModel(family: string | undefined): boolean {
  return family === CHIEF_FAMILY;
}
