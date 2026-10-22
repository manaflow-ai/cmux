// The chat's stage as the agent pane lays it out (App.tsx): VirtualTranscript with Jump to latest,
// over a bottom stack that lies across the transcript's foot. The test hands it rows
// (`window.__showRows`, drawn as a running turn with its live line under it) and how many asks are
// open in other chats (`window.__setAsksElsewhere`): with any, Jump to latest is the Needs your input
// pill, shown at the latest message too.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/ui/glass/glass.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/needsYou/needsYou.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%" });

/// The bottom stack's stand-in: a card of a composer's height over the transcript's foot.
const DOCK_HEIGHT = 120;

function Stage({ rows, elsewhere }: { rows: AcpmuxRow[]; elsewhere: number }) {
  const [dock, setDock] = useState<HTMLElement | null>(null);
  return (
    <div style={{ position: "relative", height: "100%", display: "flex", flexDirection: "column", overflow: "hidden" }}>
      <VirtualTranscript
        rows={turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow: true })}
        sessionId="session-1"
        working
        jumpButton
        needsYou={elsewhere > 0 ? { count: elsewhere, elsewhere, next: () => undefined } : undefined}
        dock={dock}
        onToggleActivity={() => undefined}
        expanded={new Set()}
      />
      <div
        ref={setDock}
        className="harness-dock"
        style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: DOCK_HEIGHT }}
      />
    </div>
  );
}

const view = createRoot(root);
let shown: AcpmuxRow[] = [];
let asks = 0;
const draw = () => view.render(<Stage rows={shown} elsewhere={asks} />);
Object.assign(window, {
  __showRows(rows: AcpmuxRow[]) {
    shown = rows;
    draw();
  },
  __setAsksElsewhere(count: number) {
    asks = count;
    draw();
  },
});
