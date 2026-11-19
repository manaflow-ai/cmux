// The composer's look (Leo 2026-10-22: "first dot claude, second dot codex. since it's just all looks
// anyways"): one composer, two looks of the same controls. Both lay +, the prompt, the mic and Send
// out as Claude's compact layout: + left of the prompt, the send slot and the mic right of it on the
// prompt's row (Leo 2026-11-01: "the placement of the buttons are just really bad compared to our
// claude code version", then "we already have a good version"). `claude` draws the mode, the model
// and effort and the context ring in the quiet row under the box; `codex` draws that row inside the
// chat's box under the prompt (Leo 2026-10-30: "the bypass/context/model picker stuff should
// literally be inside the composer box"; 2026-11-02: "switching to the codex view in the middle of an
// agent chat doesn't do anything right now"), Codex's folder and computer tray tucked under the box's
// top edge, and the accent on Full access (composerLook.css). Replaced: Codex's own row in the box
// under the prompt with + in it (cmux #28901, last good commit 8b44a8a1dc2), kept in gallery
// `agent-pane.composer-look` `codex-chat-alt-in-box-row`. Chat dots pick the look on hover in the
// composer's bottom area (LookSwitch.tsx). The choice stays in localStorage across chats, panes
// and launches. New Tab always uses Claude's look, including its shared controls.
// Settings' `agentPane.composerLook` (composerSettings.ts) set to `codex` or `claude` draws that look
// over the stored choice, so a cmuxProfile can carry it; `auto` (the default) keeps the stored one.
// While a look is set, a dot asks the host to write the setting (`pane.setComposerLook {look}`).
// `studio` is a third look only Settings picks (a setup's `agentPane.composerLook`, the Studio
// look): Codex's in-box row laid out as the Studio reference composer draws it, the model, effort
// and access chips on the row's left, the attach paperclip and a round accent Send on its right
// (composerLook.css `data-composer-variant="studio"`). It has no dot of its own: the dots offer it
// only while it is the look, so a pick of Claude or Codex can leave it.
import { useContext, useSyncExternalStore } from "react";
import { composerSettingsSnapshot, setComposerSettings, subscribeComposerSettings } from "./composerSettings";
import { OnNewTab } from "./newTabComposer";

/// The looks the chat's dots offer, in their order.
export const COMPOSER_LOOKS = ["claude", "codex"] as const;
/// Every look: the dots' and Settings' own (`studio`).
export const ALL_COMPOSER_LOOKS = ["claude", "codex", "studio"] as const;
export type ComposerLook = (typeof ALL_COMPOSER_LOOKS)[number];

/// Whether `look` draws the mode, model and effort row inside the box (Codex's and Studio's).
export function lookRowInBox(look: ComposerLook): boolean {
  return look !== "claude";
}

/// A dot's name, over it while pointed at.
export const COMPOSER_LOOK_NAMES: Readonly<Record<ComposerLook, string>> = {
  // l10n-allow: product names (Claude, Codex), never translated.
  claude: "Claude",
  // l10n-allow: product names (Claude, Codex), never translated.
  codex: "Codex",
  // l10n-allow: a look's name, as Settings' Composer Look choice names it.
  studio: "Studio",
};

/// New viewers use Codex's look across agent families; explicit choices remain saved.
export const DEFAULT_COMPOSER_LOOK: ComposerLook = "codex";
const KEY = "cmux.composer.look";

function parse(value: unknown): ComposerLook {
  return value === "claude" || value === "codex" || value === "studio" ? value : DEFAULT_COMPOSER_LOOK;
}

/// The page's copy, for a page with no storage; storage's when there is one.
let fallback: ComposerLook = DEFAULT_COMPOSER_LOOK;
/// A look shown without being remembered (a gallery stage), over the stored one.
let shown: ComposerLook | undefined;
const listeners = new Set<() => void>();

/// The look the viewer chose (storage's, else the page's copy), under any gallery stage's shown one.
export function savedComposerLook(): ComposerLook {
  try {
    return globalThis.localStorage ? parse(globalThis.localStorage.getItem(KEY)) : fallback;
  } catch {
    return fallback;
  }
}

/// The look Settings sets (`agentPane.composerLook`), when it sets one: it wins over the stored one.
function settingLook(): ComposerLook | undefined {
  const look = composerSettingsSnapshot().composerLook;
  return look === "auto" ? undefined : look;
}

function current(): ComposerLook {
  return shown ?? settingLook() ?? savedComposerLook();
}

/// The host's write of `agentPane.composerLook` (`pane.setComposerLook {look}`).
let composerLookHost: ((look: ComposerLook) => unknown) | undefined;

/// App's route to the host; a page with none (a gallery, a test) keeps the pick in the page.
export function registerComposerLookHost(write: ((look: ComposerLook) => unknown) | undefined) {
  composerLookHost = write;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    // A null key is the storage cleared (localStorage.clear()): the look is back to the default.
    if (event.key === KEY || event.key === null) listener();
  };
  globalThis.addEventListener?.("storage", onStorage);
  // Settings' look (agentPane.composerLook) arrives on the host's `composer` event.
  const offSettings = subscribeComposerSettings(listener);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", onStorage);
    offSettings();
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
  if (settingLook()) {
    // Settings pins a look: the page shows the pick at once (its subscribers hear it) and asks the
    // host to write it, whose next `composer` value is authoritative.
    setComposerSettings({ composerLook: fallback });
    try {
      void Promise.resolve(composerLookHost?.(fallback)).catch(() => undefined);
    } catch {
      // The page keeps the pick (above).
    }
  }
  for (const listener of listeners) listener();
}

/// The composer's look; re-renders the caller when it changes, here or in another pane.
export function useComposerLook(): ComposerLook {
  const onNewTab = useContext(OnNewTab);
  const look = useSyncExternalStore(subscribe, current, current);
  return onNewTab ? "claude" : look;
}
