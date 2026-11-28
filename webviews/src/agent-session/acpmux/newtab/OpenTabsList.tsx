// The Open Tabs list of a New Tab page a split opened (cx-jfo7): this workspace's tabs, each one
// a button that moves the tab into the page's pane (the host closes the page once it has).
import { useRef } from "react";
import { ContextMenu } from "../../../ui/ContextMenu";
import type { OmnibarContext } from "../omnibar";
import { useListMotion } from "./listMotion";
import { RowGlyph } from "./RowGlyph";
import { useNt } from "./strings";

export function OpenTabsList({ tabs, onMoveHere }: { tabs: OmnibarContext["tabs"]; onMoveHere(id: string): void }) {
  const nt = useNt();
  const list = useRef<HTMLElement>(null);
  useListMotion(
    list,
    ".nt-row-host > .nt-row",
    tabs.map((tab) => tab.id),
  );
  if (tabs.length === 0) return null;
  return (
    <nav ref={list} className="nt-open-tabs" aria-label={nt("openTabs")}>
      <div className="nt-open-tabs-head">{nt("openTabs")}</div>
      {tabs.map((tab) => (
        // Its right-click menu: Move Here, as its click (cx-2lm4).
        <ContextMenu
          key={tab.id}
          className="nt-row-host"
          items={[{ id: "move", label: nt("moveHere"), onSelect: () => onMoveHere(tab.id) }]}
        >
          <button type="button" className="nt-row nt-open-tab" onClick={() => onMoveHere(tab.id)}>
            {tab.icon ? (
              <img className="nt-row-glyph nt-row-favicon" src={tab.icon} alt="" draggable={false} />
            ) : (
              <RowGlyph kind={tab.kind} />
            )}
            <span className="nt-row-title">{tab.title}</span>
            {tab.detail && <span className="nt-row-detail">{tab.detail}</span>}
            <span className="nt-row-action">{nt("moveHere")}</span>
          </button>
        </ContextMenu>
      ))}
    </nav>
  );
}
