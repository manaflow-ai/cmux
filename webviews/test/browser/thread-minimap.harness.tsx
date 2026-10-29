// The chat's transcript with its thread minimap, as the agent pane lays it out (App.tsx), in the
// dark reference theme the minimap's numbers were measured in. The test hands it rows
// (`window.__showRows`); thread-minimap-motion.test.ts measures the rail's motion here.
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { TurnActionsContext } from "../../src/agent-session/acpmux/conversation/turnActions";
import { setBookmarkTransport } from "../../src/agent-session/acpmux/threadMinimap/bookmarks";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
// The liquid glass next, as dev.tsx and the bundle load it: the user bubble is `.ui-glass`.
import "../../src/ui/glass/glass.css";
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
// The motion tests measure the compact (Codex) rail; `?layout=full` shows the full-height map.
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
  "thread-minimap-layout": new URLSearchParams(location.search).get("layout") === "full" ? "full" : "compact",
};

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
document.documentElement.style.setProperty("--agent-text", "rgb(218 218 218)");
document.documentElement.style.setProperty("--agent-page-bg", "rgb(22 22 22)");
document.documentElement.style.setProperty("--acpmux-base", "rgb(22 22 22)");
document.body.style.background = "rgb(22 22 22)";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

const view = createRoot(root);
// A prompt's sent images read through `window.__imageUrl(id)` when the test sets it (the pane reads
// them from acpmux); a test serves that URL as late as it likes.
const actions = {
  promptImage: (id: string) =>
    Promise.resolve((window as unknown as { __imageUrl?: (id: string) => string | undefined }).__imageUrl?.(id)),
};
(window as unknown as { __showRows: (rows: AcpmuxRow[]) => void }).__showRows = (rows) =>
  view.render(
    <TurnActionsContext.Provider value={actions}>
      <VirtualTranscript
        rows={turnView(rows, new Set())}
        sessionId="minimap-session"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />
    </TurnActionsContext.Provider>,
  );

// The chat's bookmarks, answered as acpmux answers them: a test marks prompts (by their seq, rows
// `user-<seq>`) with `window.__setMarks`.
let marks: number[] = [];
const transport = {
  get: async (sessionId: string) => ({ sessionId, bookmarks: marks }),
  set: async (sessionId: string, seq: number, on: boolean) => {
    marks = on ? [...new Set([...marks, seq])] : marks.filter((entry) => entry !== seq);
    return { sessionId, bookmarks: marks };
  },
};
setBookmarkTransport(transport);
(window as unknown as { __setMarks: (seqs: number[]) => void }).__setMarks = (seqs) => {
  marks = seqs;
  setBookmarkTransport(transport);
};
