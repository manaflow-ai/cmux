// The New Tab rows' glyph when there is no favicon (POLISH, cx-9br4q): one icon from the cmux pack
// at 14 px in the rows' dim text, the same in the field's suggestions, Open Tabs and Recently Closed.
import { Icon } from "../icons/Icon";
import type { TabKind } from "../NewTabPage";
import type { ClosedItem } from "./recentlyClosed";
import type { ScreenRow } from "./screenModel";

/// A create row draws its kind's glyph (New chat the agent's), so "create" itself has none.
type GlyphKind = Exclude<ScreenRow["type"], "create"> | TabKind | ClosedItem["kind"];

const NAMES: Record<GlyphKind, string> = {
  // A suggestion row's type.
  tab: "omnibar.switchtab",
  history: "history",
  open: "link.open.newtab",
  search: "search",
  ask: "agent.chat",
  action: "composer.command",
  // A tab's or closed item's kind.
  terminal: "terminal",
  browser: "browser",
  agent: "agent.chat",
  screen: "tunable.panes",
  workspace: "workspace",
};

export function RowGlyph({ kind }: { kind: GlyphKind }) {
  return (
    <span className="nt-row-glyph nt-row-icon" data-kind={kind}>
      <Icon name={NAMES[kind]} size={14} />
    </span>
  );
}
