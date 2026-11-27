// The real VirtualTranscript with the unread "New" line in its rows and the reader's seen cursor
// (`readThrough`), as a person sees it coming back to a chat that kept working while they were away
// from it (acpmux hub/seen.rs `read_through`, jumpControl.ts). The
// browser test (agent-pane-unread-jump.browser.test.ts) presses Jump up, remounts the transcript as a
// tab switch inside the page does, and reads where the line lands.
import { createRoot, type Root } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const host = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(host.style, { height: "100%", display: "flex", flexDirection: "column" });
let view: Root | undefined;
let shown: AcpmuxRow[] = [];
let sinceKey: string | undefined;
let readThrough: number | undefined;

const draw = () =>
  view?.render(
    <VirtualTranscript
      rows={turnView(shown, new Set())}
      sessionId="unread-jump"
      sinceKey={sinceKey}
      readThrough={readThrough}
      onToggleActivity={() => {}}
      expanded={new Set()}
      sends={0}
      jumpButton
    />,
  );
const mount = () => {
  view = createRoot(host);
  flushSync(draw);
};
mount();

const api = window as unknown as {
  __showRows(rows: AcpmuxRow[], since?: string, through?: number): void;
  __remount(): void;
};
api.__showRows = (rows, since, through) => {
  shown = rows;
  sinceKey = since;
  readThrough = through;
  flushSync(draw);
};
/// Unmounts the transcript and mounts it again on the same rows: the unread mark's state lives
/// outside the component (conversation/unreadState.ts), as it does across a tab switch in one page.
api.__remount = () => {
  view?.unmount();
  mount();
};
