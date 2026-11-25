// l10n-allow-file: test fixture prompt, not shipped UI.
// A Cloud start's view and the chat that takes its place (cmux#55540), each drawn as the pane draws it:
// CloudStartView in the stage under the header (PaneBody.tsx `cloudStartShown`), and the started chat's
// first turn (the prompt and its running Thinking line) in the real VirtualTranscript, over the same
// docked composer. cloud-start-handoff-browser.test.ts shows one, then the other (`__handoff.show`), and
// reads where the prompt's bubble and the status line sit in each.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { CloudStartView } from "../../src/agent-session/acpmux/CloudStartView";
import type { CloudStartProgress } from "../../src/agent-session/acpmux/cloudStartProgress";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnViewFrom } from "../../src/agent-session/acpmux/conversation/turns";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/bottomStack.css";

const PROMPT = "what's in this folder?";
const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

type Shown = "start" | "chat";
let shown: Shown = "start";
let width: number | undefined;
let dock: HTMLElement | null = null;
const view = createRoot(root);

const start: CloudStartProgress = {
  key: "handoff",
  task: PROMPT,
  state: "starting",
  step: "machine",
  startedAt: Date.now(),
} as CloudStartProgress;
const raw: AcpmuxRow[] = [{ id: "prompt", version: 1, at: Date.now(), kind: "user", text: PROMPT } as AcpmuxRow];

const draw = () =>
  view.render(
    <div className="acpmux-shell" style={{ width: width ?? "100%", height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          {shown === "start" ? (
            <CloudStartView start={start} />
          ) : (
            <VirtualTranscript
              rows={turnViewFrom(raw, new Set(), { working: true, agentFamily: "claude" }).rows}
              sessionId="handoff"
              working
              dock={dock}
              onToggleActivity={() => {}}
              expanded={new Set()}
            />
          )}
        </div>
        <div
          ref={(node) => {
            if (node && node !== dock) {
              dock = node;
              draw();
            }
          }}
          className="acpmux-dock"
        >
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: 56 }} />
          </form>
        </div>
      </div>
    </div>,
  );

(
  window as unknown as {
    __handoff: { show(next: Shown, options?: { width?: number }): void; loadStrings(): Promise<void> };
  }
).__handoff = {
  show(next, options = {}) {
    shown = next;
    if (options.width !== undefined) width = options.width;
    flushSync(draw);
  },
  async loadStrings() {
    globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
    const { setPaneLanguage } = await import("../../src/agent-session/acpmux/i18n");
    setPaneLanguage("en");
  },
};
draw();
