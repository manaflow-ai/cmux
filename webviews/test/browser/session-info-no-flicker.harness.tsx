// l10n-allow-file: test fixture chat text, not shipped UI.
// The agent pane as App.tsx lays it out around Session Info: the shell, the chat column with its
// transcript and its composer dock, and the real useSessionInfo panel, open. The test streams a reply
// into it (`window.__step(n)`): every update a new snapshot, as acpmux sends them, with the reply one
// token longer, a tool call that produces nothing, the dock's live line, and a usage tick that changes
// no number Session Info shows.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../../src/agent-session/acpmux/model";
import { activity, assistant, chat, CWD, tool, user } from "../../src/gallery/fixtures/acpmux";
import { setHeaderState } from "../../src/agent-session/acpmux/header/headerState";
import { ChatHeaderTools } from "../../src/agent-session/acpmux/header/ChatHeaderTools";
import { useSessionInfo } from "../../src/agent-session/acpmux/session-info/SessionInfo";
import { setSessionInfoOpen } from "../../src/agent-session/acpmux/session-info/sessionInfoState";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/bottomStack.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

const first = chat([
  user("Add retries to the fetch helper", 4),
  activity(
    [
      tool("Edit src/fetch.ts", "edit", "completed", {
        diffs: [{ path: `${CWD}/src/fetch.ts`, oldText: "a\n", newText: "a\nb\n" }],
      }),
    ],
    3,
  ),
]);

/// The chat on update `step`: every array and object new, as a snapshot is.
function streamed(step: number): AcpmuxSnapshot {
  const runs = Array.from({ length: Math.floor(step / 5) }, (_, index) =>
    tool(`Run git status ${index}`, "execute", "completed"),
  );
  const rows: AcpmuxRow[] = [
    ...first.rows.map((row) => ({ ...row })),
    activity(runs, 2),
    { ...assistant("Retrying with backoff ".repeat(step), 1), streaming: true },
  ];
  return {
    ...first,
    rows,
    // Running from the first update on, which the test settles before it watches: the dock's live line
    // coming in grows the composer stack, and the card over the chat rightly stops above it.
    isWorking: true,
    summary: { ...first.summary!, usage: { ...first.summary!.usage! } },
    sessions: first.sessions.map((entry) => ({ ...entry })),
  };
}

let show: (snapshot: AcpmuxSnapshot) => void = () => {};
let panelRenders = 0;

function Pane() {
  const [snapshot, setSnapshot] = useState(first);
  const [shell, setShell] = useState<HTMLElement | null>(null);
  show = setSnapshot;
  // As App.tsx passes them: callbacks made again on every render.
  const sessionInfo = useSessionInfo({
    snapshot,
    shell,
    machineName: "Studio",
    onOpenOutput: (path) => void path,
    onOpenUrl: (url) => void url,
    onOpenFolder: (path) => void path,
    processes: { processes: [], listed: true },
    onRender: () => panelRenders++,
  });
  return (
    <section
      className="acpmux-shell"
      style={{ flex: 1, minHeight: 0 }}
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <div className="acpmux-main">
        <header className="acpmux-header">
          <div />
          <ChatHeaderTools
            onTerminal={() => undefined}
            onBrowser={() => undefined}
            summary={null}
            menu={() => []}
            sessionInfo={sessionInfo.button}
          />
        </header>
        <div className="acpmux-scroll" style={{ padding: "16px 24px", overflow: "auto", flex: 1 }}>
          {snapshot.rows.map((row) => (
            <div key={row.id} className="acpmux-row" style={{ margin: "12px 0" }}>
              {row.text ?? row.items?.map((item) => item.text).join(", ")}
            </div>
          ))}
        </div>
        <div className="acpmux-dock">
          {snapshot.isWorking && <div className="acpmux-activity-line">Working</div>}
          <div className="acpmux-composer" style={{ height: 72 }} />
        </div>
      </div>
      {sessionInfo.panel}
    </section>
  );
}

setHeaderState({ inspector: true });
setSessionInfoOpen(true);
createRoot(root).render(<Pane />);

declare global {
  interface Window {
    __step(step: number): void;
    __renders(): number;
  }
}
window.__step = (step) => flushSync(() => show(streamed(step)));
window.__renders = () => panelRenders;
