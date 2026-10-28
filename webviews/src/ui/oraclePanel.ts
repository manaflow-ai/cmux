// The open panels of the refactor oracle's `webviews` facet (protocol/oracle-state.ts):
// each shared overlay (dialog, which sheets use too, popover, menu) names its kind while it is open, so every page
// that uses them reports its panels with no code of its own. Kinds, never labels: a label is
// localized text. Developer builds only; elsewhere contributeOracleState keeps nothing.
import { useEffect } from "react";
import { contributeOracleState } from "../protocol/oracle-state";

/** The kinds of panel the shared overlays report. */
export type OraclePanelKind = "dialog" | "popover" | "menu";

/** Reports `kind` in the page's open panels while `open`. */
export function useOraclePanel(kind: OraclePanelKind, open: boolean): void {
  useEffect(() => (open ? contributeOracleState(() => ({ panels: [kind] })) : undefined), [kind, open]);
}
