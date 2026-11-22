// A running turn as the agent pane shapes it (App.tsx `turnRowsShown` and `transcriptRows`): its raw
// rows through turnViewFrom, the inbox projection, the subagent rows, the merged inbox notices and the
// waiting messages' group over the live line, drawn by the real VirtualTranscript over a docked
// composer. thinking-gap-browser.test.ts hands it rows (`__gap.show`) and reads, on every painted
// frame, how far the running turn's Thinking line is from the last row over it that draws.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { toggleTurnFold, turnViewFrom } from "../../src/agent-session/acpmux/conversation/turns";
import { projectInboxRows } from "../../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { mergeInboxNotices } from "../../src/agent-session/acpmux/conversation/inboxNotice";
import { pendingMessagesRow, withWaitingRows } from "../../src/agent-session/acpmux/conversation/pendingMessages";
import { subagentRowsFrom } from "../../src/agent-session/acpmux/subagents/subagentRows";
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
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/markdownField.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

let shown: AcpmuxRow[] = [];
let working = true;
let expanded = new Set<string>();
let width: number | undefined;
let lastPending: AcpmuxRow | undefined;
const view = createRoot(root);

/// The rows the pane hands VirtualTranscript for `shown` (App.tsx, the parts a chat with no shell,
/// no hat plan and no queue uses).
function shape(): AcpmuxRow[] {
  const turns = turnViewFrom(shown, expanded, { working, agentFamily: "claude" });
  const display = projectInboxRows(turns.rows);
  const subagents = subagentRowsFrom(display, expanded);
  const group = pendingMessagesRow(turns.pending ?? [], [], lastPending);
  lastPending = group;
  return withWaitingRows(mergeInboxNotices([...subagents.rows]), group ? [group] : []);
}

let dock: HTMLElement | null = null;
const draw = () =>
  view.render(
    <div className="acpmux-shell" style={{ width: width ?? "100%", height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={shape()}
            sessionId="thinking-gap"
            working={working}
            jumpButton
            dock={dock}
            onToggleActivity={(id) => {
              expanded = toggleTurnFold(shown, expanded, id);
              draw();
            }}
            expanded={expanded}
          />
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
    __gap: {
      show(rows: AcpmuxRow[], options?: { working?: boolean; width?: number; sync?: boolean }): void;
      loadStrings(): Promise<void>;
    };
  }
).__gap = {
  show(rows, options = {}) {
    shown = rows;
    if (options.working !== undefined) working = options.working;
    if (options.width !== undefined) width = options.width;
    if (options.sync) flushSync(draw);
    else draw();
  },
  async loadStrings() {
    globalThis.__cmuxPaneStrings ??= (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
    const { setPaneLanguage } = await import("../../src/agent-session/acpmux/i18n");
    setPaneLanguage("en");
  },
};
draw();
