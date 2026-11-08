import type React from "react";
import type { StringKey } from "./i18n";

/// Picker copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const PICKER_LABELS = {
  model: "picker.model",
  mode: "picker.mode",
  /// The access chip's tooltip: what the control is (a tester asked what the shield chip does).
  modeHelp: "picker.modeHelp",
  /// A mode the agent or the organization's managed settings refused.
  modeRefused: "picker.modeRefused",
  effort: "picker.effort",
  plan: "picker.plan",
  build: "picker.build",
  fullAccessWarning: "picker.fullAccessWarning",
  /// A full-access row while MDM or a team policy keeps full access off (#23322).
  fullAccessManaged: "picker.fullAccessManaged",
  /// The chip of a chat whose acpmux policy answers every prompt (approve-all) in a mode that asks.
  approvesAll: "picker.approvesAll",
  approvesAllDetail: "picker.approvesAllDetail",
  /// `{percent}` is the share of the context window used.
  context: "picker.context",
} as const satisfies Record<string, StringKey>;

/// A model and effort the viewer used, kept per viewer so the menu can offer it as one click.
export type Combo = { harness: string; model: string; effort?: string; effortName?: string };
/// A combo counts as used once it has held this long: model and effort land in separate updates.
export const RECENT_SETTLE_MS = 1500;
const RECENTS_KEY = "cmux.acpmux.recentModels";

/// The viewer's recent combos, newest first. Storage can be missing or blocked; then there are none.
export function loadRecents(): Combo[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(RECENTS_KEY) ?? "[]");
    return Array.isArray(value)
      ? value.filter(
          (combo): combo is Combo =>
            typeof combo?.harness === "string" &&
            typeof combo.model === "string" &&
            (combo.effort === undefined || typeof combo.effort === "string") &&
            (combo.effortName === undefined || typeof combo.effortName === "string"),
        )
      : [];
  } catch {
    return [];
  }
}

/// Puts `combo` first, once, and keeps the list short. Saving is best effort.
/// It builds on what is stored now, so another pane's newer combos aren't written over.
export function rememberCombo(recents: Combo[], combo: Combo): Combo[] {
  const key = (other: Combo) => `${other.harness}\u0000${other.model}\u0000${other.effort ?? ""}`;
  const same = (other: Combo) => key(other) === key(combo);
  const known = new Set<string>();
  const merged = [...loadRecents(), ...recents].filter((other) => !known.has(key(other)) && known.add(key(other)));
  if (merged[0] && same(merged[0])) return merged;
  const next = [combo, ...merged.filter((other) => !same(other))].slice(0, 12);
  try {
    localStorage.setItem(RECENTS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the list for this page only.
  }
  return next;
}

export type Choice = {
  id: string;
  name: string;
  description?: string;
  icon?: React.ReactNode;
  hint?: string;
  /// The level the model recommends (its catalog default): the effort slider marks it.
  recommended?: boolean;
};

/// Plan modes (an id ending in "plan") read and propose without editing; the toggle sits apart from the permission chip.
export function isPlan(modeId: string): boolean {
  return /(^|[-_])plan$/i.test(modeId);
}

// The markers of cmux-tui/spec/full-access-modes.json, the rule acpmux and the app enforce.
const FULL_ACCESS_MARKERS = ["bypass", "fullaccess", "yolo", "dangerous", "autoapprove", "skippermissions"];

/// Modes that skip approvals (such as "Full access") draw in the theme's warning color: lowercased,
/// without `-`, `_` or spaces, the id contains a full-access marker.
export function unrestricted(modeId: string): boolean {
  const folded = modeId.toLowerCase().replace(/[-_ ]/g, "");
  return FULL_ACCESS_MARKERS.some((marker) => folded.includes(marker));
}

/** Send's return glyph (↵) in Claude's look, drawn in Claude Code desktop's proportions: a wider
 *  bar, a taller stem and a fuller arrowhead with a tight corner (Leo 2026-11-02: "our send button i
 *  think can be nicer lokoing ... compared to claude code"). At the composer's 18 px trailing glyph
 *  its ink is about 13 × 12 px, Claude Code's. */
export const RETURN_GLYPH_PATH = "M13.1 3.45v4.1a1.2 1.2 0 0 1-1.2 1.2H2.9M6.7 4.95 2.9 8.75l3.8 3.8";
export const LEVEL_KEYS: Record<string, StringKey> = {
  low: "effort.level.low",
  medium: "effort.level.medium",
  high: "effort.level.high",
  xhigh: "effort.level.xhigh",
  max: "effort.level.max",
  ultra: "effort.level.ultra",
  // A new chat that starts on Ultracode (its saved pick); never a level row (reasoningChoices).
  ultracode: "effort.level.ultracode",
};
/// A model's name without its vendor, for the controls row: `short`, the catalog's own short
/// name, when the name ends with it ("Claude Opus 5.5" -> "Opus 5.5"), else the name less a first
/// word its harness's name starts with ("Claude" of "Claude Code", "Gemini" of "Gemini CLI").
/// Undefined when there is nothing to drop.
export function shortModelName(name: string, short?: string, harnessName?: string): string | undefined {
  const trimmed = short?.trim();
  if (trimmed && trimmed.length < name.length && name.endsWith(` ${trimmed}`)) return trimmed;
  const vendor = harnessName?.trim().split(/\s+/)[0];
  const space = name.indexOf(" ");
  if (!vendor || space <= 0) return undefined;
  const rest = name.slice(space + 1).trim();
  return rest && name.slice(0, space).toLowerCase() === vendor.toLowerCase() ? rest : undefined;
}

/// The name an alias draws once the release it runs is known: the release's (`release`, "Opus 5.5")
/// when the alias's own name (`name`) is only that release's family ("Opus"), or the family and a
/// variant ("Opus · 1M context" while it runs "Opus 5.5 · 1M context"). The alias's variant stays when
/// the release's name has none ("Opus · 1M context" running "Opus 5.5" is "Opus 5.5 · 1M context").
/// Any other name stays: it says more than the family ("Opus plan · Sonnet execute").
export function aliasNamedAsRelease(name: string, release: string): string {
  const family = modelFamily(release.replace(/^claude\s+/i, ""))?.toLowerCase();
  const head = name
    .split("·")[0]!
    .trim()
    .toLowerCase()
    .replace(/^claude\s+/, "");
  if (!family || head !== family) return name;
  const variant = name.indexOf("·");
  return variant > 0 && !release.includes("·") ? `${release} ${name.slice(variant).trim()}` : release;
}

/// A model's family for a narrow controls row: its name's first word ("Opus" of "Opus 5.5") when
/// that word is a name of at least 3 letters and not the whole name. Undefined otherwise.
export function modelFamily(name: string): string | undefined {
  const first = name.trim().split(/\s+/)[0] ?? "";
  return first !== name.trim() && /\p{L}{3,}/u.test(first) ? first : undefined;
}

/// The plain levels a catalog row can list (`PickerModel.efforts`).
const PLAIN_LEVELS = new Set(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]);

/// The Reasoning section's rows: the agent's levels, named by the pane, narrowed to what the
/// running model supports when its catalog row says. The agent-owned default sentinel is omitted,
/// and so are an older acpmux's Ultracode (now its own switch) and Ultrathink (a prompt keyword,
/// not a level).
export function reasoningChoices(
  options: { value: string; name?: string; description?: string }[],
  model: { efforts?: readonly string[]; defaultEffort?: string; own?: { efforts?: true }; noEffort?: true } | undefined,
  t: (key: StringKey) => string,
): Choice[] {
  if (model?.noEffort || (model?.own?.efforts && (model.efforts ?? []).length === 0)) return [];
  const levels = model?.efforts && model.efforts.length > 0 ? new Set<string>(model.efforts) : undefined;
  const offered = options.filter((option) => {
    if (["default", "ultracode", "ultrathink"].includes(option.value)) return false;
    if (!levels) return true;
    return !PLAIN_LEVELS.has(option.value) || levels.has(option.value);
  });
  return offered.map((option) => {
    const key = LEVEL_KEYS[option.value];
    const base: Choice = { id: option.value, name: key ? t(key) : option.name || option.value };
    if (option.value === model?.defaultEffort) base.recommended = true;
    return base;
  });
}
