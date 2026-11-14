// The real Composer with a turn the browser test starts and ends (send-stop-morph.browser.test.ts):
// `__set({ working, sessionId, look })` redraws it as App.tsx does when acpmux's snapshot changes.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Composer } from "../../src/agent-session/acpmux/Composer";
import { setComposerLook, type ComposerLook } from "../../src/agent-session/acpmux/composerLook";
import { noChat } from "../../src/gallery/fixtures/acpmux";
import "../../src/pages/shared/desktop";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/composerLook.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";

type State = { working: boolean; sessionId: string; look: ComposerLook };
let state: State = { working: false, sessionId: "chat-a", look: "claude" };
const root = document.getElementById("root")!;
Object.assign(root.style, { width: "640px", padding: "24px" });
const view = createRoot(root);
const sends: string[] = [];

function Chips() {
  return null;
}

const draw = () => {
  setComposerLook(state.look, { remember: false });
  const { sessionId, working } = state;
  view.render(
    <div className="acpmux-shell" style={{ display: "block", height: "auto", width: "600px" }}>
      <Composer
        snapshot={noChat([], {
          sessionId,
          isWorking: working,
          summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
        })}
        sessionId={sessionId}
        chips={Chips}
        onSend={(text: string) => {
          sends.push(text);
          return true;
        }}
        onStop={() => {}}
        onNewChat={() => {}}
        localName="studio"
      />
    </div>,
  );
};

Object.assign(window, {
  __set(next: Partial<State>) {
    if (next.sessionId !== undefined && next.sessionId !== state.sessionId)
      Object.assign(window, { __scopeAt: performance.now() });
    state = { ...state, ...next };
    // In the same task, as a snapshot push commits: the test reads the next frame.
    flushSync(draw);
  },
  __sends: () => sends.slice(),
  __scopeAt: performance.now(),
});
draw();
