// The chat's transcript as the agent pane lays it out (App.tsx), with the pane's debug API
// (debug.ts) over it as the app installs it, so a test drives the same seed and fling the
// frame pacing bench does (scripts/ci/frame-pacing/bench.sh).
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { createAcpmuxDebug, type AcpmuxDebug } from "../../src/agent-session/acpmux/debug";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/previewCard/previewCard.css";
import "../../src/agent-session/acpmux/changes/changes.css";
import "../../src/agent-session/acpmux/turnChanges/turnChanges.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/keys.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

let current: AcpmuxRow[] = [];
let show: (rows: AcpmuxRow[]) => void = () => {};
function Transcript() {
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  show = setRows;
  return (
    <VirtualTranscript
      rows={turnView(rows, new Set())}
      sessionId="session-1"
      onToggleActivity={() => {}}
      expanded={new Set()}
    />
  );
}
createRoot(root).render(<Transcript />);
(window as unknown as { __debug: AcpmuxDebug }).__debug = createAcpmuxDebug({
  replaceRows(rows) {
    current = rows;
    show(rows);
  },
  rowCount: () => current.length,
});
