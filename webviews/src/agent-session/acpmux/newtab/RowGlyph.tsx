// The New Tab rows' glyph when there is no favicon (POLISH, cx-9br4q): one icon from the cmux pack
// at 14 px in the rows' dim text, the same in the field's suggestions, Open Tabs and Recently Closed.
import { Icon } from "../icons/Icon";

const NAMES: Record<string, string> = {
  // A suggestion row's type.
  tab: "omnibar.switchtab",
  history: "history",
  open: "link.open.newtab",
  search: "search",
  // A tab's or closed item's kind.
  terminal: "terminal",
  browser: "browser",
  agent: "agent.chat",
  screen: "tunable.panes",
  workspace: "workspace",
};

export function RowGlyph({ kind }: { kind: string }) {
  return (
    <span className="nt-row-glyph nt-row-icon" data-kind={kind}>
      <Icon name={NAMES[kind] ?? "tab.new"} size={14} />
    </span>
  );
}
