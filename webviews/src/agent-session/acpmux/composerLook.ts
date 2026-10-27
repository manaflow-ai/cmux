// The composer's look (Leo 2026-10-22: "first dot claude, second dot codex. since it's just all looks
// anyways"): one composer, two layouts of the same controls. `claude`, the default, is today's
// composer, Claude Code's (with the plain footer, the mode, model and effort in the quiet row under
// the box). `codex` lays them out as Codex desktop does: one row inside the box under the prompt, +
// and the mode on the left, the model and effort, the mic and Send on the right, and on New Tab the
// folder and computer strip a tray tucked under the box's top edge (composerLocation.css,
// newtab/screen.css). Dots pick it: on New Tab the page's three (newtab/tabDots.ts: Claude Minimal,
// Claude Minimal with the quick actions, Codex Minimal), in a chat two on hover in the composer's
// bottom area (LookSwitch.tsx). The choice is the
// viewer's, kept in localStorage across chats, panes and launches (in step by the `storage` event),
// as the transcript's wrap choice is (conversation/blockWrap.ts).
import { useSyncExternalStore } from "react";
import { useComposerSettings } from "./composerSettings";

export const COMPOSER_LOOKS = ["claude", "codex"] as const;
export type ComposerLook = (typeof COMPOSER_LOOKS)[number];

/// A dot's name, over it while pointed at.
export const COMPOSER_LOOK_NAMES: Readonly<Record<ComposerLook, string>> = {
  // l10n-allow: product names (Claude, Codex), never translated.
  claude: "Claude",
  // l10n-allow: product names (Claude, Codex), never translated.
  codex: "Codex",
};

/// The default: Claude's look, the composer as it was before the dots.
export const DEFAULT_COMPOSER_LOOK: ComposerLook = "claude";
const KEY = "cmux.composer.look";

function parse(value: unknown): ComposerLook {
  return value === "codex" ? "codex" : DEFAULT_COMPOSER_LOOK;
}

/// The page's copy, for a page with no storage; storage's when there is one.
let fallback: ComposerLook = DEFAULT_COMPOSER_LOOK;
/// A look shown without being remembered (a gallery stage), over the stored one.
let shown: ComposerLook | undefined;
const listeners = new Set<() => void>();

function current(): ComposerLook {
  if (shown) return shown;
  try {
    return globalThis.localStorage ? parse(globalThis.localStorage.getItem(KEY)) : fallback;
  } catch {
    return fallback;
  }
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    // A null key is the storage cleared (localStorage.clear()): the look is back to the default.
    if (event.key === KEY || event.key === null) listener();
  };
  globalThis.addEventListener?.("storage", onStorage);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", onStorage);
  };
}

/// Sets every composer's look, and remembers it; with `remember: false` (a gallery stage) the page
/// shows it without writing it.
export function setComposerLook(look: ComposerLook, { remember = true }: { remember?: boolean } = {}) {
  if (!remember) {
    shown = parse(look);
    for (const listener of listeners) listener();
    return;
  }
  shown = undefined;
  fallback = parse(look);
  try {
    globalThis.localStorage?.setItem(KEY, fallback);
  } catch {
    // Storage off: the page's copy still holds it.
  }
  for (const listener of listeners) listener();
}

/// The composer's look; re-renders the caller when it changes, here or in another pane.
export function useComposerLook(): ComposerLook {
  return useSyncExternalStore(subscribe, current, current);
}

/// Whether the mode, model and effort sit in the quiet row under the box (Claude's look with the
/// plain footer, ComposerFoot.tsx) rather than in the box's own row (Codex's look, or the plain
/// footer off).
export function useQuietRow(): boolean {
  const { plainFooter } = useComposerSettings();
  const look = useComposerLook();
  return plainFooter && look === "claude";
}
