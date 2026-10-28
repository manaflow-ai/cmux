// The Recently Closed section of the New Tab page (cx-d0d.60): the newest closed tabs, screens
// and workspaces, each one a button that reopens it through History's path (`tab.jump` with
// target `closed`). An item whose machine is not connected is drawn dimmed and disabled.
import { useRef } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import { pressToOpen } from "../../../ui/pressToOpen";
import { useListMotion } from "./listMotion";
import type { ClosedItem } from "./recentlyClosed";
import { RowGlyph } from "./RowGlyph";
import { useNt } from "./strings";

/// The rows the section shows at most.
const SHOWN = 5;

export function ClosedList({ items, onReopen }: { items: ClosedItem[]; onReopen(id: string): void }) {
  const nt = useNt();
  const list = useRef<HTMLElement>(null);
  const shown = items.slice(0, SHOWN);
  useListMotion(
    list,
    ".nt-row-host > .nt-row",
    shown.map((item) => item.id),
  );
  if (items.length === 0) return null;
  return (
    <nav ref={list} className="nt-open-tabs nt-closed" aria-label={nt("recentlyClosed")}>
      <div className="nt-open-tabs-head">{nt("recentlyClosed")}</div>
      {shown.map((item) => (
        // Its right-click menu: Reopen, as its click (cx-2lm4).
        <ContextMenu
          key={item.id}
          className="nt-row-host"
          items={[{ id: "reopen", label: nt("reopen"), disabled: !item.available, onSelect: () => onReopen(item.id) }]}
        >
          <button
            type="button"
            className="nt-row nt-open-tab"
            disabled={!item.available}
            {...pressToOpen(() => onReopen(item.id))}
          >
            {item.icon ? (
              <img className="nt-row-glyph nt-row-favicon" src={item.icon} alt="" draggable={false} />
            ) : (
              <RowGlyph kind={item.kind} />
            )}
            <span className="nt-row-title">{item.title}</span>
            {item.detail && <span className="nt-row-detail">{item.detail}</span>}
            <span className="nt-row-action">{nt("reopen")}</span>
          </button>
        </ContextMenu>
      ))}
    </nav>
  );
}
