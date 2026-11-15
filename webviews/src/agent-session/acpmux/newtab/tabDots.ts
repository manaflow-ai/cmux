// The New Tab page's look dots (Leo 2026-10-23: "1 CLAUDE MINIMAL ... 3 CODEX MINIMAL"): Claude's
// composer and Codex's composer. A dot keeps no state of its own: it is the composer's look
// (composerLook.ts, the viewer's, in storage). The middle dot, Claude Minimal with the quick action
// pills, went with the New Tab widgets (Lawrence 2026-11-09: "remove widgets completely"). The other
// page styles are not dots of this row (StyleSwitch.tsx).
import { COMPOSER_LOOK_NAMES, setComposerLook, type ComposerLook } from "../composerLook";
import type { NewTabTranslate } from "./strings";

export const NEW_TAB_DOTS = ["claude", "codex"] as const;
export type NewTabDot = (typeof NEW_TAB_DOTS)[number];

/// The composer look each dot shows.
export const DOT_LOOKS: Readonly<Record<NewTabDot, ComposerLook>> = {
  claude: "claude",
  codex: "codex",
};

/// The dot the page is on, from the look.
export function shownDot(look: ComposerLook): NewTabDot {
  return look === "codex" ? "codex" : "claude";
}

/// A dot's name, over it while pointed at and its radio's: "Claude Minimal", "Codex Minimal" (the
/// product names are never translated; Minimal is the page's own word).
export function dotName(dot: NewTabDot, nt: NewTabTranslate): string {
  return `${COMPOSER_LOOK_NAMES[DOT_LOOKS[dot]]} ${nt("template.minimal")}`;
}

/// A dot picked: the composer's look, at once.
export function pickDot(dot: NewTabDot): void {
  setComposerLook(DOT_LOOKS[dot]);
}
