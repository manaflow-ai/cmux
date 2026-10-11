// The Open Tabs list of a New Tab page a split opened (cx-jfo7): this workspace's tabs, each one
// a button that moves the tab into the page's pane (the host closes the page once it has).
import type { OmnibarContext } from "../omnibar";
import { useNt } from "./strings";

export function OpenTabsList({ tabs, onMoveHere }: { tabs: OmnibarContext["tabs"]; onMoveHere(id: string): void }) {
  const nt = useNt();
  if (tabs.length === 0) return null;
  return (
    <nav className="nt-open-tabs" aria-label={nt("openTabs")}>
      <div className="nt-open-tabs-head">{nt("openTabs")}</div>
      {tabs.map((tab) => (
        <button key={tab.id} type="button" className="nt-row nt-open-tab" onClick={() => onMoveHere(tab.id)}>
          {tab.icon ? (
            <img className="nt-row-glyph nt-row-favicon" src={tab.icon} alt="" draggable={false} />
          ) : (
            <span className="nt-row-glyph" data-kind={tab.kind} />
          )}
          <span className="nt-row-title">{tab.title}</span>
          {tab.detail && <span className="nt-row-detail">{tab.detail}</span>}
          <span className="nt-row-action">{nt("moveHere")}</span>
        </button>
      ))}
    </nav>
  );
}
