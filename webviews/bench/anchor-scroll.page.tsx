// l10n-allow-file: benchmark page, not shipped UI.
// The page anchor-scroll.bench.ts drives: a menu anchored (ui/anchor.ts useUiAnchor) to a button
// inside a scroller, open, with rows that fit under it.
import { useRef } from "react";
import { createRoot } from "react-dom/client";
import { useUiAnchor } from "../src/ui/anchor";

function Menu() {
  const anchor = useRef<HTMLButtonElement>(null);
  const overlay = useRef<HTMLDivElement>(null);
  const style = useUiAnchor(anchor, overlay, true);
  return (
    <div id="scroller" style={{ position: "relative", height: 600, overflow: "auto" }}>
      <div style={{ height: 3000, paddingTop: 200 }}>
        <button ref={anchor}>open</button>
        <div ref={overlay} style={{ ...style, overflow: "auto" }}>
          {Array.from({ length: 12 }, (_, i) => (
            <div key={i} style={{ height: 24 }}>
              row {i}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Menu />);
