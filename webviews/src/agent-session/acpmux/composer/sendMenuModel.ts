// The send slot's menu (SendMenu.tsx): the ways one draft can go, and the key that sends it each
// way from the prompt. The keys are the Return forms the app leaves to a focused composer
// (KeyBindingDefaults.textInputKeys, exported as the action catalog's `text_input_keys`: "Return
// sends and its Command, Shift and Option forms steer, add a line or send another way"), so no
// app binding takes them from the prompt. Shift-Return adds a line; the other three are these.
// Run on several agents is ⌘⌥Return: Command and Option together, which no app binding takes in
// a chat (Toggle Browser Focus Mode has it only in a focused browser; ⌘⇧Return is Ghostty's Toggle
// Pane Zoom, reserved in every pane).
// The menu draws its keys from this table and the composer's key handler reads the same table,
// so a key drawn on a row is the key that runs it.

import { CMUX_COMMANDS } from "../cmuxCommands";
import type { StringKey } from "../i18n";
import { FORK_ICON } from "../icons/forkIcon";

export type SendChoice = "send" | "queue" | "side" | "runOn";

/** `/side`, which Send in side chat runs with the draft as its prompt (cmuxCommands.ts). */
export const SIDE_COMMAND = CMUX_COMMANDS.find((command) => command.action === "side");

export type SendKey = {
  /** Command held (⌘). */
  meta: boolean;
  /** Option held (⌥). */
  alt: boolean;
  /** The key as the menu draws it, one glyph per key: ["⌘", "↩"]. */
  glyphs: readonly string[];
  /** The key in `aria-keyshortcuts` form. */
  aria: string;
};

export const SEND_KEYS: Record<SendChoice, SendKey> = {
  send: { meta: false, alt: false, glyphs: ["↩"], aria: "Enter" },
  queue: { meta: true, alt: false, glyphs: ["⌘", "↩"], aria: "Meta+Enter" },
  side: { meta: false, alt: true, glyphs: ["⌥", "↩"], aria: "Alt+Enter" },
  runOn: { meta: true, alt: true, glyphs: ["⌘", "⌥", "↩"], aria: "Meta+Alt+Enter" },
};

/** The row's name, in the pane's strings. */
export const SEND_LABELS: Record<SendChoice, StringKey> = {
  send: "composer.send",
  queue: "composer.sendMenuQueue",
  side: "composer.sendMenuSide",
  runOn: "runOn.menu",
};

/** The row's icon (the icon look only; icons/cmuxIcons.json). */
export const SEND_ICONS: Record<SendChoice, string> = {
  send: "composer.send",
  queue: "time.waiting",
  side: FORK_ICON,
  runOn: "git.worktree",
};

/** The way a Return key press sends, or undefined for any other key (Shift-Return adds a line). */
export function sendChoiceForKey(event: {
  key: string;
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
}): SendChoice | undefined {
  if (event.key !== "Enter" || event.shiftKey || event.ctrlKey) return undefined;
  return (Object.keys(SEND_KEYS) as SendChoice[]).find(
    (choice) => SEND_KEYS[choice].meta === event.metaKey && SEND_KEYS[choice].alt === event.altKey,
  );
}

/**
 * The rows the menu shows, in order. A way that would do what Send does, or that this chat cannot
 * do now, has no row (never a disabled one):
 * - `queue` only while a turn runs and Send takes the prompt into it (`sendSteers`): otherwise Send
 *   already queues behind the turn, or there is no turn to wait for.
 * - `side` only where `/side <prompt>` forks this chat (`side`): the side chat's prompt takes the
 *   draft's files too (#40066).
 * - `runOn` (Run on several agents…, runOnAgents/) only where this chat can start runs (`runOn`)
 *   and the draft is text alone: each run's first prompt is the typed text.
 * A menu with Send alone is no menu: the slot keeps its ordinary right-click.
 */
export function sendMenuChoices(state: {
  draft: boolean;
  sendSteers: boolean;
  side: boolean;
  files?: boolean;
  runOn?: boolean;
}): SendChoice[] {
  if (!state.draft) return [];
  const choices: SendChoice[] = ["send"];
  if (state.sendSteers) choices.push("queue");
  if (state.side) choices.push("side");
  if (state.runOn && !state.files) choices.push("runOn");
  return choices.length > 1 ? choices : [];
}
