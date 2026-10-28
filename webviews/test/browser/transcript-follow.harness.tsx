// The chat's transcript as the agent pane lays it out (App.tsx): VirtualTranscript fills a fixed
// height. The test hands it rows (`window.__showRows`), as a chat's snapshots do while a reply streams.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript, type ScrollAnchor } from "../../src/agent-session/acpmux/App";
import { followTrace } from "../../src/agent-session/acpmux/followTrace";
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

const view = createRoot(root);
// "Worked for" lines open and close as the pane's do: a click toggles the turn in `expanded`.
let shown: AcpmuxRow[] = [];
let expanded = new Set<string>();
// Prompts "sent" from the pane's composer (App's `chat.send`), which put the view at its latest message.
let sends = 0;
// Where the chat reopens (`__openAt`, the reader's saved place). Its row is in an older page that never
// lands, so the open keeps paging back for it, unseen, until it gives up or a prompt is sent.
let openAt: ScrollAnchor | undefined;
// The chat shown (`__showSession`), as the pane's tab switches chats.
let sessionId = "session-1";
let dock: HTMLElement | null = null;
let working = false;
const draw = () =>
  view.render(
    <VirtualTranscript
      rows={turnView(shown, expanded)}
      sessionId={sessionId}
      onToggleActivity={(id) => {
        expanded = new Set(expanded);
        if (!expanded.delete(id)) expanded.add(id);
        draw();
      }}
      expanded={expanded}
      sends={sends}
      dock={dock}
      working={working}
      openAt={openAt}
      canLoadOlder={openAt !== undefined}
      onLoadOlder={() => new Promise<void>(() => {})}
    />,
  );
(window as unknown as { __showRows: (rows: AcpmuxRow[]) => void }).__showRows = (rows) => {
  shown = rows;
  draw();
};
(window as unknown as { __showRowsSync: (rows: AcpmuxRow[]) => void }).__showRowsSync = (rows) => {
  shown = rows;
  flushSync(draw);
};
(window as unknown as { __showSession: (id: string, rows: AcpmuxRow[]) => void }).__showSession = (id, rows) => {
  sessionId = id;
  shown = rows;
  draw();
};
(window as unknown as { __send: () => void }).__send = () => {
  sends += 1;
  draw();
};
(window as unknown as { __openAt: (anchor: ScrollAnchor) => void }).__openAt = (anchor) => {
  openAt = anchor;
  draw();
};
(window as unknown as { __followSnapshot: () => ReturnType<typeof followTrace.snapshot> }).__followSnapshot = () =>
  followTrace.snapshot();
(window as unknown as { __touchDock: (queued: boolean) => void }).__touchDock = (queued) => {
  if (!dock) {
    dock = document.createElement("div");
    Object.assign(dock.style, { position: "fixed", bottom: "0", width: "100%", pointerEvents: "none" });
    document.body.append(dock);
  }
  dock.innerHTML = queued
    ? '<div class="acpmux-queued" data-prompt-id="touch-queued" style="height:100px"></div><div class="acpmux-composer-box" style="height:80px"></div>'
    : '<div class="acpmux-composer-box" style="height:80px"></div>';
  working = true;
  flushSync(draw);
};
