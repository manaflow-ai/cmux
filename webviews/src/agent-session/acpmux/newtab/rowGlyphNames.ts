import type { TabKind } from "../newTabModel";
import type { ClosedItem } from "./recentlyClosed";
import type { ScreenRow } from "./screenModel";

export type GlyphKind = ScreenRow["type"] | TabKind | ClosedItem["kind"];

export const NAMES: Record<GlyphKind, string> = {
  // A suggestion row's type.
  tab: "omnibar.switchtab",
  history: "history",
  open: "link.open.newtab",
  search: "search",
  ask: "agent.chat",
  action: "composer.command",
  create: "action.add",
  inProfile: "browser.toolbar.profile",
  profile: "browserprofile.badge",
  newProfile: "action.add",
  launch: "folder",
  run: "terminal",
  resume: "action.resume",
  // A tab's or closed item's kind.
  terminal: "terminal",
  browser: "browser",
  agent: "agent.chat",
  screen: "tunable.panes",
  workspace: "workspace",
};

/// The cmux pack icon a suggestion row draws (a create row's by its kind), for Send's glyph when
/// Return takes that row.
export function rowGlyphName(row: ScreenRow): string {
  if (row.type === "create") return NAMES[row.kind === "chat" ? "agent" : row.kind];
  if (row.type === "action") return NAMES.action;
  return NAMES[row.type];
}
