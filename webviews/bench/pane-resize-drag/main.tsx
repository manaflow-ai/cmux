// l10n-allow-file: bench harness, not shipped UI.
// The chat's transcript as the agent pane lays it out, over a long chat (longChat.ts), for
// pane-resize-drag.bench.ts. The same mount as test/browser/transcript-fling.harness.tsx (the page
// the transcript drag tests and transcript-resize-frame.bench.ts drive): VirtualTranscript with the
// pane's styles, its rows shaped by turnView as the pane shapes them, the thread minimap on. Only
// the rows differ, so this page adds nothing to the fling harness, which it does not touch.
//   window.__seedLong(turns)  replaces the chat with `turns` turns of longChat.ts
//   window.__acpmuxPerf       the pane's own measuring module (perf.ts), as the fling harness hands it over
/// <reference types="vite/client" />
import { useLayoutEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import * as acpmuxPerfModule from "../../src/agent-session/acpmux/perf";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { longChatRows } from "./longChat";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx), the list the fling harness loads.
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

/// One empty fold set for every render (a fresh Set would read as a fold change).
const NO_FOLDS: ReadonlySet<string> = new Set<string>();
const NO_EXPANDED = new Set<string>();
const noop = () => {};

type BenchWindow = {
  __seedLong: (turns: number) => { turns: number; rows: number };
  /// The rows turnView shaped for the transcript at its last render.
  __shapedRows: () => number;
  __acpmuxPerf: typeof acpmuxPerfModule;
};
const bench = window as unknown as BenchWindow;

let show: (rows: AcpmuxRow[]) => void = () => {};
let shapedCount = 0;

function Transcript() {
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  show = setRows;
  // Shaped once per chat, never per render: the drag re-renders the transcript, not this component,
  // but a memo keeps the harness out of any frame it could reach.
  const shaped = useMemo(() => turnView(rows, NO_FOLDS), [rows]);
  useLayoutEffect(() => {
    shapedCount = shaped.length;
  }, [shaped]);
  return (
    <VirtualTranscript
      rows={shaped}
      sessionId="pane-resize-drag"
      jumpButton
      showMinimap
      onToggleActivity={noop}
      expanded={NO_EXPANDED}
    />
  );
}

createRoot(root).render(<Transcript />);
bench.__acpmuxPerf = acpmuxPerfModule;
bench.__shapedRows = () => shapedCount;
bench.__seedLong = (turns: number) => {
  const rows = longChatRows(Math.max(1, Math.floor(turns)));
  show(rows);
  return { turns, rows: rows.length };
};
