// The real VirtualTranscript with a controllable send preference. The browser test drives this
// page like App.tsx: a send changes the follow decision, then a prompt and streamed reply arrive.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { shouldScrollToBottomAfterSend } from "../../src/agent-session/acpmux/sendScrollSetting";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
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
let shown: AcpmuxRow[] = [];
let expanded = new Set<string>();
let sends = 0;
let following = true;
let scrollToBottomOnSend = true;
let dock: HTMLElement | null = null;

const draw = () =>
  view.render(
    <VirtualTranscript
      rows={turnView(shown, expanded)}
      sessionId="send-scroll-setting"
      onToggleActivity={(id) => {
        expanded = new Set(expanded);
        if (!expanded.delete(id)) expanded.add(id);
        draw();
      }}
      expanded={expanded}
      sends={sends}
      dock={dock}
      jumpButton
      onFollowingChange={(next) => {
        following = next;
      }}
    />,
  );

(window as unknown as { __showRows(rows: AcpmuxRow[]): void }).__showRows = (rows) => {
  shown = rows;
  draw();
};
(window as unknown as { __showRowsSync(rows: AcpmuxRow[]): void }).__showRowsSync = (rows) => {
  shown = rows;
  flushSync(draw);
};
(window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend = (enabled) => {
  scrollToBottomOnSend = enabled;
};
(window as unknown as { __send(): void }).__send = () => {
  if (shouldScrollToBottomAfterSend(scrollToBottomOnSend, following)) sends += 1;
  draw();
};
(window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState = () => ({
  following,
  sends,
});
(window as unknown as { __dock(queued: boolean): void }).__dock = (queued) => {
  if (!dock) {
    dock = document.createElement("div");
    Object.assign(dock.style, { position: "fixed", bottom: "0", width: "100%", pointerEvents: "none" });
    document.body.append(dock);
  }
  dock.innerHTML = queued
    ? '<div class="acpmux-queued" style="height:100px"></div><div class="acpmux-composer-box" style="height:80px"></div>'
    : '<div class="acpmux-composer-box" style="height:80px"></div>';
  flushSync(draw);
};
draw();
