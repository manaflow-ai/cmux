// The chat's transcript as the agent pane lays it out (App.tsx): VirtualTranscript fills a fixed
// height. The test hands it rows (`window.__showRows`), as a chat's snapshots do while a reply streams.
import { useState } from "react";
import { createRoot as createReactRoot } from "react-dom/client";
import { VirtualTranscript, type ScrollAnchor } from "../../src/agent-session/acpmux/App";
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

const view = createReactRoot(root);
// "Worked for" lines open and close as the pane's do: a click toggles the turn in `expanded`.
let shown: AcpmuxRow[] = [];
let expanded = new Set<string>();
// Prompts "sent" from the pane's composer (App's `chat.send`), which put the view at its latest message.
let sends = 0;
let controlPresses = 0;
// Where the chat reopens (`__openAt`, the reader's saved place). Its row is in an older page that never
// lands, so the open keeps paging back for it, unseen, until it gives up or a prompt is sent.
let openAt: ScrollAnchor | undefined;
// The chat shown (`__showSession`), as the pane's tab switches chats.
let sessionId = "session-1";
function Harness() {
  const [bottomDock, setBottomDock] = useState<HTMLElement | null>(null);
  const [showBottomDock, setShowBottomDock] = useState(false);
  (window as unknown as { __showBottomDock: () => void }).__showBottomDock = () => setShowBottomDock(true);
  return (
    <div
      className="test-main"
      style={{ position: "relative", height: "100%", display: "flex", flexDirection: "column" }}
    >
      <div className="acpmux-main" style={{ position: "relative", height: "100%", display: "flex" }}>
        <div className="acpmux-stage" style={{ position: "relative", height: "100%", flex: 1, display: "flex" }}>
          <VirtualTranscript
            rows={turnView(shown, expanded)}
            sessionId={sessionId}
            dock={bottomDock}
            onToggleActivity={(id) => {
              expanded = new Set(expanded);
              if (!expanded.delete(id)) expanded.add(id);
              draw();
            }}
            expanded={expanded}
            sends={sends}
            openAt={openAt}
            canLoadOlder={openAt !== undefined}
            onLoadOlder={() => new Promise<void>(() => {})}
          />
        </div>
        {showBottomDock && (
          <div
            ref={setBottomDock}
            className="test-bottom-dock"
            style={{ position: "absolute", inset: "auto 0 0", height: 96, pointerEvents: "none" }}
          >
            <div
              className="acpmux-composer-strip"
              data-testid="bottom-selection-strip"
              style={{
                position: "absolute",
                left: "max(18px, calc((100% - 760px) / 2))",
                right: "max(18px, calc((100% - 760px) / 2))",
                bottom: 24,
                height: 30,
                pointerEvents: "auto",
              }}
            >
              {/* Production strips put this full-width context box around their controls. The
                  blank part must still be a valid transcript-selection start surface. */}
              <div className="acpmux-composer-context">
                <button
                  type="button"
                  data-testid="bottom-selection-control"
                  style={{ position: "absolute", right: 4, top: 4 }}
                  onPointerDown={() => {
                    controlPresses += 1;
                  }}
                >
                  Keep control ownership
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

const draw = () => view.render(<Harness />);
(window as unknown as { __showRows: (rows: AcpmuxRow[]) => void }).__showRows = (rows) => {
  shown = rows;
  draw();
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
(window as unknown as { __controlPresses: () => number }).__controlPresses = () => controlPresses;
(window as unknown as { __openAt: (anchor: ScrollAnchor) => void }).__openAt = (anchor) => {
  openAt = anchor;
  draw();
};
