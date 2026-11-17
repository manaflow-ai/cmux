// The New Tab rows' glyph when there is no favicon (POLISH, cx-9br4q): one icon from the cmux pack
// at 14 px in the rows' dim text, the same in the field's suggestions, Open Tabs and Recently Closed.
import { AgentMark } from "../../shared/AgentMark";
import { CommandGlyph } from "../icons/CommandGlyph";
import { Icon } from "../icons/Icon";
import type { TabKind } from "../newTabModel";
import type { ClosedItem } from "./recentlyClosed";
import type { ScreenRow } from "./screenModel";

type GlyphKind = ScreenRow["type"] | TabKind | ClosedItem["kind"];

const NAMES: Record<GlyphKind, string> = {
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
  chat: "agent.chat",
  launch: "folder",
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

export function SuggestionGlyph({ row }: { row: ScreenRow }) {
  if (row.type === "create") return <RowGlyph kind={row.kind === "chat" ? "agent" : row.kind} />;
  if (row.type === "ask")
    return (
      <span className="nt-row-glyph nt-row-icon" aria-hidden="true">
        <AgentMark agent={row.harness} size={14} fallback={<Icon name="agent.chat" size={14} />} />
      </span>
    );
  if (row.type === "action")
    return (
      <span className="nt-row-glyph nt-row-icon" aria-hidden="true">
        <CommandGlyph symbol={row.symbol} />
      </span>
    );
  return <RowGlyph kind={row.type} />;
}
