import { transcriptLiveVars } from "../transcriptGrid";

/// The live line's box and gap in a run as custom properties on the scroller (transcriptGrid.ts transcriptLiveVars):
/// conversation.css sizes the line with them. Constant, so the scroller's per-scroll restyle never changes them.
export const LIVE_STEP_VARS = transcriptLiveVars();
