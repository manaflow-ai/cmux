// The New Tab rows' glyph (POLISH, cx-9br4q): one icon from the cmux pack in the rows' dim text, the
// same in the field's suggestions, Open Tabs and Recently Closed. A tab's or page's favicon takes the
// icon's place inside the same box, at the icon's size, at every density (Lucas 2026-11-18).
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

export function RowGlyph({ kind, icon }: { kind: GlyphKind; icon?: string }) {
  if (icon)
    return (
      <span className="nt-row-glyph" data-kind={kind} aria-hidden="true">
        <img className="nt-row-favicon" src={icon} alt="" draggable={false} />
      </span>
    );
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
  const icon = row.type === "tab" || row.type === "history" ? row.icon : undefined;
  return <RowGlyph kind={row.type} {...(icon ? { icon } : {})} />;
}
