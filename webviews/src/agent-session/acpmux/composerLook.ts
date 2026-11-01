// The composer's look (Leo 2026-10-22: "first dot claude, second dot codex. since it's just all looks
// anyways"): one composer, two looks of the same controls. Both lay the buttons out as Claude's, the
// default: + left of the prompt, the send slot and the mic right of it on the prompt's row, and the
// mode, the model and effort and the context ring in the quiet row under the box (Leo 2026-11-01:
// "the placement of the buttons are just really bad compared to our claude code version", then "we
// already have a good version"). `codex` keeps only Codex's folder and computer tray tucked under
// the box's top edge and the accent on Full access (composerLook.css). Replaced: Codex's own row in
// the box under the prompt (cmux #28901, last good commit 8b44a8a1dc2), kept in gallery
// `agent-pane.composer-look` `codex-chat-alt-in-box-row`. Dots pick it: on New Tab the page's three
// (newtab/tabDots.ts: Claude Minimal, Claude Minimal with the quick actions, Codex Minimal), in a chat
// two on hover in the composer's bottom area (LookSwitch.tsx). The choice is the viewer's, kept in
// localStorage across chats, panes and launches (in step by the `storage` event), as the transcript's
// wrap choice is (conversation/blockWrap.ts).
import { useSyncExternalStore } from "react";

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
