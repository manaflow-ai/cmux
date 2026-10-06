// An agent's "default" model or reasoning level, as the composer names it. Agents name these
// "Default (Claude Code's choice)", "Default (model's choice)" or "default (agent's choice)";
// the composer never shows that phrasing. A default model draws as the model it resolves to,
// once known, else as "Default"; a default reasoning level draws as "Default" inside the menu
// and not at all on the model chip. Menus mark the default choice with a small hint instead.
import type { AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const DEFAULT_ID = "default";
const DEFAULT_NAME = /^default\b/i;

/// Whether a model or effort choice is the agent's own default.
export function isDefaultChoice(choice: { id: string; name?: string }): boolean {
  return choice.id.toLowerCase() === DEFAULT_ID || DEFAULT_NAME.test(choice.name ?? "");
}

/// A readable name for a Claude model id the catalog does not list: "claude-opus-5-5" is
/// "Opus 5.5", "claude-haiku-4-5-20251001" is "Haiku 4.5", a `[1m]` suffix adds "1M context".
/// Any other id is returned as it is.
export function modelIdName(id: string): string {
  const claude = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$/i.exec(id);
  if (!claude) return id;
  const [, family, major, minor, wide] = claude;
  const name = `${family![0]!.toUpperCase()}${family!.slice(1).toLowerCase()} ${major}${minor ? `.${minor}` : ""}`;
  return wide ? `${name} · 1M context` : name;
}

/// The model the session actually runs when it asked for the default: the agent reports it as
/// its model option's current value once it starts (Claude Code's `init`), while the session's
/// own model stays the "default" it asked for.
export function resolvedModel(summary: Pick<Summary, "model" | "configOptions"> | undefined): string | undefined {
  if (!summary?.model || summary.model.toLowerCase() !== DEFAULT_ID) return undefined;
  const option = summary.configOptions?.find((candidate) => candidate.category === "model" || candidate.id === "model");
  const current = option?.currentValue;
  return typeof current === "string" && current && current.toLowerCase() !== DEFAULT_ID ? current : undefined;
}

const STORAGE_KEY = "cmux.acpmux.resolvedDefaults";

/// The model each harness's default last resolved to, so a new chat that has not started yet
/// names it. Per viewer; a missing or blocked store only means "Default" until the chat starts.
export function loadResolvedDefaults(): Record<string, string> {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    return parsed && typeof parsed === "object" ? (parsed as Record<string, string>) : {};
  } catch {
    return {};
  }
}

export function rememberResolvedDefault(harness: string, model: string): void {
  try {
    const all = loadResolvedDefaults();
    if (all[harness] === model) return;
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify({ ...all, [harness]: model }));
  } catch {
    // Storage unavailable: the next new chat says "Default" until it starts.
  }
}
