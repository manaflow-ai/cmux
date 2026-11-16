// Session Info's parts as tests and galleries find them in the DOM. One spelling per part;
// scripts/check-pane-selectors.ts refuses these strings typed raw in a test or gallery and names the
// constant to import.
import { TRANSCRIPT_OVERLAYS } from "../overlayLayout";

const PANEL = TRANSCRIPT_OVERLAYS.sessionInfo.className;

/// The Session Info panel the pane renders (galleries also draw bare `.acpmux-session-info` cards).
export const SESSION_INFO = `aside.${PANEL}`;
/// The Session Info panel while it is shown.
export const SESSION_INFO_SHOWN = `${SESSION_INFO}[data-presence="shown"]`;
/// The header button that shows and hides Session Info (useSessionInfo.tsx, PanelToggle).
export const SESSION_INFO_TOGGLE = `button.${PANEL}-toggle`;
/// The Session Info toggle while the panel is hidden.
export const SESSION_INFO_TOGGLE_OFF = `${SESSION_INFO_TOGGLE}[aria-pressed="false"]`;
