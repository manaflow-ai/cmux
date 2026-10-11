// The Recently Closed section of the New Tab page (cx-d0d.60): the newest closed tabs, screens
// and workspaces, each one a button that reopens it through History's path (`tab.jump` with
// target `closed`). An item whose machine is not connected is drawn dimmed and disabled.
import type { ClosedItem } from "./recentlyClosed";
import { useNt } from "./strings";

/// The rows the section shows at most.
const SHOWN = 5;

/// A kind's glyph when there is no favicon, in the style of the field's rows.
const GLYPH: Record<ClosedItem["kind"], string> = { terminal: "❯", browser: "◍", screen: "▭", workspace: "▦" };

export function ClosedList({ items, onReopen }: { items: ClosedItem[]; onReopen(id: string): void }) {
  const nt = useNt();
  if (items.length === 0) return null;
  return (
    <nav className="nt-open-tabs nt-closed" aria-label={nt("recentlyClosed")}>
      <div className="nt-open-tabs-head">{nt("recentlyClosed")}</div>
      {items.slice(0, SHOWN).map((item) => (
        <button
          key={item.id}
          type="button"
          className="nt-row nt-open-tab"
          disabled={!item.available}
          onClick={() => onReopen(item.id)}
        >
          {item.icon ? (
            <img className="nt-row-glyph nt-row-favicon" src={item.icon} alt="" draggable={false} />
          ) : (
            <span className="nt-row-glyph" data-kind={item.kind}>
              {GLYPH[item.kind]}
            </span>
          )}
          <span className="nt-row-title">{item.title}</span>
          {item.detail && <span className="nt-row-detail">{item.detail}</span>}
          <span className="nt-row-action">{nt("reopen")}</span>
        </button>
      ))}
    </nav>
  );
}
