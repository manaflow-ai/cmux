// The transcript's parts as tests and galleries find them in the DOM. One spelling per part:
// when a part's identity changes (Jump up carries Jump to latest's class, #40326), it changes here
// and every lookup follows. scripts/check-pane-selectors.ts refuses these strings typed raw in a
// test or gallery and names the constant to import.
import { TRANSCRIPT_OVERLAYS } from "./overlayLayout";

const JUMP = TRANSCRIPT_OVERLAYS.jumpToLatest.className;
const JUMP_UP = TRANSCRIPT_OVERLAYS.jumpUp.className;

/// Jump to latest, never its companion Jump up (which carries the same class and renders first).
export const JUMP_LATEST = `.${JUMP}:not(.${JUMP_UP})`;
/// Jump to latest while it shows.
export const JUMP_LATEST_SHOWN = `${JUMP_LATEST}[data-shown]`;
/// A transcript row that carries its row id.
export const TRANSCRIPT_ROW = ".acpmux-row[data-row-id]";
