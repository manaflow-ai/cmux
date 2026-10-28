// The Settings page's part of the refactor oracle's `webviews` facet (protocol/oracle-state.ts):
// the shown category as the route, the focused setting's key as the selection, the
// search's results or Changed filter as panels, and the search text only as its SHA-256 (the route
// leaves `?q=` out, so the text never leaves the page). Dialogs and pickers report themselves
// (ui/oraclePanel.ts).
import type { OracleStateReading } from "../../protocol/oracle-state";
import type { SettingsLocation } from "./router";

/** The page's reading for `location`, with `section` the category it shows. */
export function settingsOracleReading(location: SettingsLocation, section: string): OracleStateReading {
  const panels: string[] = [];
  if (location.query.trim()) panels.push("search");
  if (location.changedOnly) panels.push("changed");
  return {
    route: `/settings/${section}`,
    selection: location.focus,
    panels,
    draft: location.query,
  };
}
