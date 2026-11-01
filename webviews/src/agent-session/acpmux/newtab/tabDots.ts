// The New Tab page's three dots (Leo 2026-10-23: "1 CLAUDE MINIMAL / 2 CLAUDE MINIMAL + NEW
// TAB/TERMINAL/WHATEVER / 3 CODEX MINIMAL"). Minimal is what every dot is, not a mode that hides
// things: the first dot is Claude's composer alone (the default), the second the same composer with
// the quick action pills under it (New terminal, New browser tab, New chat), the third Codex's
// composer alone. The rest (the other page styles, projects, chats) are settings and widgets, never
// dots.
//
// A dot keeps no state of its own: it is the composer's look (composerLook.ts, the viewer's, in
// storage) and the quick actions widget (`tabs.newTabWidgets.actions`, pageWidgets.ts, a setting the
// host sends). Codex's look is the third dot; Claude's with the actions on the second; else the
// first. A pick sets both: the look in place, the widget as the page's edit mode writes it
// (`newTab.editWidgets`). Codex's look with the actions ("2 AND 3 MAYBE SWITCHABLE") is room left
// for later, not a dot yet: it shows as the third.
import { COMPOSER_LOOK_NAMES, setComposerLook, type ComposerLook } from "../composerLook";
import { editNewTabWidgets, type WidgetEdit } from "./pageWidgets";
import type { NewTabTranslate } from "./strings";

export const NEW_TAB_DOTS = ["claude", "claudeActions", "codex"] as const;
export type NewTabDot = (typeof NEW_TAB_DOTS)[number];

/// What each dot is: the composer's look, and whether the quick action pills show.
export const DOT_STATES: Readonly<Record<NewTabDot, { look: ComposerLook; actions: boolean }>> = {
  claude: { look: "claude", actions: false },
  claudeActions: { look: "claude", actions: true },
  codex: { look: "codex", actions: false },
};

/// The dot the page is on, from the look and the actions widget.
export function shownDot(look: ComposerLook, actions: boolean): NewTabDot {
  if (look === "codex") return "codex";
  return actions ? "claudeActions" : "claude";
}

/// A dot's name, over it while pointed at and its radio's: "Claude Minimal", "Claude Minimal +
/// Quick Actions", "Codex Minimal" (the product names are never translated; Minimal and Quick Actions are
/// the page's own words).
export function dotName(dot: NewTabDot, nt: NewTabTranslate): string {
  if (dot === "claudeActions")
    return `${COMPOSER_LOOK_NAMES.claude} ${nt("template.minimal")} + ${nt("widget.actions")}`;
  return `${COMPOSER_LOOK_NAMES[DOT_STATES[dot].look]} ${nt("template.minimal")}`;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A dot picked: the look at once, and the quick actions widget turned on or off as the edit mode
/// would (saved by the host, shown in place by `show`) when it is not already so.
export function pickDot(
  dot: NewTabDot,
  deps: { actions: boolean; callNative: Native; show(edit: WidgetEdit): void },
): void {
  const state = DOT_STATES[dot];
  setComposerLook(state.look);
  if (state.actions === deps.actions) return;
  editNewTabWidgets(state.actions ? { edit: "show", widget: "actions" } : { edit: "remove", widget: "actions" }, deps);
}
