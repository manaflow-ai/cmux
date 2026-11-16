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
// `agent-pane.composer-look` `codex-chat-alt-in-box-row`. Dots pick it: on New Tab the page's three
// (newtab/tabDots.ts: Claude Minimal, Claude Minimal with the quick actions, Codex Minimal), in a chat
// two on hover in the composer's bottom area (LookSwitch.tsx). The choice is the viewer's, kept in
// cmux-next.json as `agentPane.display.composerLook` (Settings > Agent Chat > Composer Style), which
// the host sends every agent page with the chat's keys (chatDisplay.ts) and writes when a dot is
// picked (`pane.setDisplay`). The page's localStorage is only the launch's copy: the agent pages'
// store is not persistent (AgentPaneView.sharedDataStore, Chromium's off-the-record profile), so a
// pick kept only there came back as Codex after every restart (Leo, 2026-11-14: "if i picked the
// claude style composer it should remember it after restart instead of always only going to the
// codex mode"). Until the host's value comes, the launch's copy shows (a page opened after a pick in
// this launch draws it from its first frame); once it came, the host's value wins.
import { useSyncExternalStore } from "react";
import {
  changeChatDisplay,
  COMPOSER_LOOK_KEY,
  notePickedElsewhere,
  pickedDisplayValue,
  subscribeChatDisplay,
} from "./chatDisplay";

export const COMPOSER_LOOKS = ["claude", "codex"] as const;
export type ComposerLook = (typeof COMPOSER_LOOKS)[number];

/// A dot's name, over it while pointed at.
export const COMPOSER_LOOK_NAMES: Readonly<Record<ComposerLook, string>> = {
  // l10n-allow: product names (Claude, Codex), never translated.
  claude: "Claude",
  // l10n-allow: product names (Claude, Codex), never translated.
  codex: "Codex",
};

/// New viewers use Codex's look across agent families; explicit choices remain saved.
export const DEFAULT_COMPOSER_LOOK: ComposerLook = "codex";
/// The launch's copy in storage (the host keeps the choice; see above).
const KEY = "cmux.composer.look";

function parse(value: unknown): ComposerLook {
  return value === "claude" || value === "codex" ? value : DEFAULT_COMPOSER_LOOK;
}

/// The page's copy, for a page with no storage; storage's when there is one.
let fallback: ComposerLook = DEFAULT_COMPOSER_LOOK;
/// A look shown without being remembered (a gallery stage), over the stored one.
let shown: ComposerLook | undefined;
const listeners = new Set<() => void>();

/// This launch's copy: storage's, else the page's.
function launchCopy(): ComposerLook {
  try {
    return globalThis.localStorage ? parse(globalThis.localStorage.getItem(KEY)) : fallback;
  } catch {
    return fallback;
  }
}

/// The look the viewer chose, under any gallery stage's shown one: the host's (cmux-next.json, the
/// default when it holds none) once its value came, this launch's copy until then.
export function savedComposerLook(): ComposerLook {
  const kept = pickedDisplayValue(COMPOSER_LOOK_KEY);
  return kept === undefined ? launchCopy() : parse(kept);
}

function current(): ComposerLook {
  return shown ?? savedComposerLook();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    // A null key is the storage cleared (localStorage.clear()): the look is back to the default.
    if (event.key !== KEY && event.key !== null) return;
    // Another page's pick is the newest: it stands over the host's last value until the host's push.
    if (event.key === KEY && (event.newValue === "claude" || event.newValue === "codex"))
      notePickedElsewhere(COMPOSER_LOOK_KEY, event.newValue);
    listener();
  };
  globalThis.addEventListener?.("storage", onStorage);
  // The host's value came or changed (a pick in another pane, Settings, an edit of the file).
  const unfollow = subscribeChatDisplay(listener);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", onStorage);
    unfollow();
  };
}

/// Sets every composer's look, and remembers it: in the page at once, in this launch's storage for
/// pages opened next, and in cmux-next.json through the host, so the next launch opens on it. With
/// `remember: false` (a gallery stage) the page shows it without writing it.
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
  // Explicit either way, so a later change of the default never moves a viewer who picked.
  changeChatDisplay(COMPOSER_LOOK_KEY, fallback);
  for (const listener of listeners) listener();
}

/// The composer's look; re-renders the caller when it changes, here or in another pane.
export function useComposerLook(): ComposerLook {
  return useSyncExternalStore(subscribe, current, current);
}
