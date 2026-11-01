// What Settings > Appearance's undo stack records: which keys a change touches, their states read
// from the page's settings, and the label the Undo and Redo buttons name.
import { sameState, type KeyState, type TargetState, type ThemeState } from "./appearanceHistory";
import { categoryRows } from "./categories";
import { displayNumber, unitLabel } from "./format";
import { rowsByKey } from "./schema";
import type { SettingsState } from "./store";
import { t, text } from "./strings";

/** The Settings pages whose rows the stack records: Appearance and Theme. */
export const APPEARANCE_CATEGORIES: readonly string[] = ["appearance", "theme"];

/** Appearance keys the page no longer shows that the app still loads (#22379): a value someone
 * set still applies, so Reset to Defaults resets it too, the only way Settings can put it back. */
const RETIRED_APPEARANCE_KEYS: readonly string[] = ["appearance.glassTransparency", "appearance.backdropArt"];

let tracked: ReadonlySet<string> | null = null;
function trackedKeys(): ReadonlySet<string> {
  tracked ??= new Set([
    ...APPEARANCE_CATEGORIES.flatMap((id) => categoryRows(id))
      .filter((row) => !row.page_hidden)
      .map((row) => row.key),
    ...RETIRED_APPEARANCE_KEYS,
  ]);
  return tracked;
}

/** Keys a write to the key also changes (`WindowBackgroundSetting.linkedEdits` on the host):
 * Opacity in Ghostty mode names the Material, and Material's reset removes Opacity. */
const LINKED: Readonly<Record<string, readonly string[]>> = {
  "appearance.backgroundOpacity": ["appearance.backgroundBlur"],
  "appearance.backgroundBlur": ["appearance.backgroundOpacity"],
};

/** Whether a write to `key` is an appearance change. */
export function tracksAppearance(key: string): boolean {
  return trackedKeys().has(key);
}

/** `keys` with the keys their writes also change, each once. */
export function withLinked(keys: readonly string[]): string[] {
  return [...new Set(keys.flatMap((key) => [key, ...(LINKED[key] ?? [])]))];
}

/** Every key Settings > Appearance edits (Reset to defaults and the opened-with snapshot). */
export function appearanceKeys(): string[] {
  return [...trackedKeys()];
}

/** The keys' states as the page has them now. */
export function captureKeys(state: SettingsState, keys: readonly string[]): KeyState[] {
  return keys.flatMap((key) => {
    const row = state.rows.get(key);
    if (!row) return [];
    return [{ kind: "setting" as const, key, value: row.value, customized: row.customized }];
  });
}

/** Each theme level of the active window, as the host lists them. */
export function captureThemes(state: SettingsState): ThemeState[] {
  const theme = state.host?.theme;
  return (theme?.levels ?? []).map((level) => ({ kind: "theme" as const, level, spec: theme?.current[level] ?? null }));
}

/** The state of every appearance target: the opened-with snapshot and Reset's starting point. */
export function captureAppearance(state: SettingsState): TargetState[] {
  return [...captureKeys(state, appearanceKeys()), ...captureThemes(state)];
}

/** The state `target`'s setting or theme level shows now; undefined when the page has no such row. */
export function currentState(state: SettingsState, target: TargetState): TargetState | undefined {
  if (target.kind === "setting") return captureKeys(state, [target.key])[0];
  return captureThemes(state).find((theme) => theme.level === target.level);
}

/** Whether every target still shows the state given for it (`sameState`). */
export function showsStates(state: SettingsState, targets: readonly TargetState[]): boolean {
  return targets.every((target) => {
    const now = currentState(state, target);
    return now !== undefined && sameState(now, target);
  });
}

/** What a target's state shows, in the page's language ("Shuffle Paintings", "45 %", "Default"). */
export function stateText(state: SettingsState, target: TargetState): string {
  if (target.kind === "theme") return target.spec ?? t("settingsPage.history.ghosttyTheme");
  const row = rowsByKey.get(target.key);
  if (!row) return String(target.value ?? "");
  const value = target.customized ? target.value : null;
  if (value === null || value === undefined) {
    return row.default_label ? text(row.default_label) : defaultText(state, target.key, row.default);
  }
  return valueTitle(state, target.key, value);
}

function defaultText(state: SettingsState, key: string, value: unknown): string {
  if (value === null || value === undefined) return t("settingsPage.history.default");
  return valueTitle(state, key, value);
}

function valueTitle(state: SettingsState, key: string, value: unknown): string {
  const row = rowsByKey.get(key);
  const choice = row?.choices?.find((item) => item.value === value);
  if (choice) return text(choice.title);
  // A background the schema lists no choice for: a picture of the host's grid, by its title.
  const backdrop = typeof value === "string" ? state.host?.backdrops?.find((item) => item.id === value) : undefined;
  if (backdrop) return backdrop.title;
  if (typeof value === "number") {
    const unit = unitLabel(row?.range);
    return unit ? `${displayNumber(value, row?.range)} ${unit}` : displayNumber(value, row?.range);
  }
  if (typeof value === "boolean") return value ? t("settingsPage.history.on") : t("settingsPage.history.off");
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}

/** The title of a target: its row's title, or Theme for a theme level. */
export function targetTitle(target: TargetState): string {
  if (target.kind === "theme") return t("settingsPage.history.theme");
  const row = rowsByKey.get(target.key);
  return row ? text(row.title) : target.key;
}

/** "Background → Shuffle Paintings": the first change's title and new state. A change that also
 * moved a linked key is named by the key the person moved (the first). */
export function changeLabel(state: SettingsState, after: TargetState): string {
  return t("settingsPage.history.change", targetTitle(after), stateText(state, after));
}
