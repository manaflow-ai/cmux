// The New Tab page's Stashed link (stash-v1): shown while tabs are stashed, it opens the Stashed
// page through `tab.jump` with target `stashed`. Its right-click menu: Open, as its click.
import { ContextMenu } from "../../../ui/ContextMenu";
import { RowGlyph } from "./RowGlyph";
import { useNt } from "./strings";

export function StashedLink({ count, onOpen }: { count: number; onOpen(): void }) {
  const nt = useNt();
  if (count <= 0) return null;
  return (
    <nav className="nt-open-tabs nt-stashed" aria-label={nt("stashed")}>
      <ContextMenu className="nt-row-host" items={[{ id: "open", label: nt("stashedOpen"), onSelect: onOpen }]}>
        <button type="button" className="nt-row nt-open-tab" onClick={onOpen}>
          <RowGlyph kind="browser" />
          <span className="nt-row-title">{nt("stashed")}</span>
          <span className="nt-row-detail">{count.toLocaleString()}</span>
          <span className="nt-row-action">{nt("stashedOpen")}</span>
        </button>
      </ContextMenu>
    </nav>
  );
}
