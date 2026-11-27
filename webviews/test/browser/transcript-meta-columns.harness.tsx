// l10n-allow-file: synthetic transcript rows for a geometry test.
// One of each transcript meta row kind, drawn by the production components, for
// transcript-meta-columns-browser.test.ts: a tool row, a sent message, a received message, an inbox
// notice, a background task and a sub-session card.
import { createRoot } from "react-dom/client";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/glass/glass.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import { ToolRow } from "../../src/agent-session/acpmux/conversation/ToolRow";
import { MessageCard } from "../../src/agent-session/acpmux/conversation/MessageCard";
import { IncomingMessageLine, IncomingNotice } from "../../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { SubsessionCallCard } from "../../src/agent-session/acpmux/conversation/SubsessionCallCard";
import { subsessionCall } from "../../src/agent-session/acpmux/conversation/subsessionCalls";
import { agentMessage } from "../../src/agent-session/acpmux/conversation/agentMessages";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
import type { AcpmuxActivity } from "../../src/agent-session/acpmux/model";

globalThis.__cmuxPaneStrings = { en: strings.en };
document.documentElement.dataset.cmuxMotion = "off";
const theme = new URLSearchParams(location.search).get("theme") === "light" ? "light" : "dark";

const call = (id: string, fields: Partial<NonNullable<AcpmuxActivity["tool"]>>): AcpmuxActivity => ({
  kind: "tool",
  text: fields.title ?? "",
  tool: { id, title: "", kind: "other", status: "completed", ...fields },
});
const read = call("meta-read", { title: "Read App.tsx", kind: "read", locations: [{ path: "/repo/App.tsx" }] });
const sent = call("meta-sent", {
  title: "SendMessage",
  inputSummary: JSON.stringify({ to: "Background pill", message: "Leo again, verbatim." }),
});
const start = call("meta-start", {
  title: "mcp__cmux-subsessions__start_session",
  inputSummary: JSON.stringify({ name: "sidebar-drag", prompt: "Fix the sidebar drag" }),
  output: "Started sub-session sidebar-drag (sessionId sidebar-id, depth 1).",
});
const inbox = "New messages from other agents in 1 thread.\n- 1 new in #1 from acpmux-owner: Ready. (thread t1)";

function App() {
  return (
    <main
      className="acpmux-shell"
      data-theme={theme}
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "stretch",
        padding: 24,
        width: 640,
        height: "auto",
      }}
    >
      <div data-meta-row="tool" className="cv-tools">
        <ToolRow item={read} />
      </div>
      <div data-meta-row="sent">
        <MessageCard item={sent} message={agentMessage(sent.tool!)!} />
      </div>
      <div data-meta-row="received">
        <IncomingMessageLine
          id="meta-received"
          message={{ name: "coord-deputy", text: "The batch is next.", raw: "[coord-deputy] The batch is next." }}
          onOpen={() => undefined}
        />
      </div>
      <div data-meta-row="inbox">
        <IncomingMessageLine
          id="meta-inbox"
          message={{ name: "inbox", text: inbox, raw: `[inbox] ${inbox}`, noticeThreads: [{ id: "t1", sender: "x" }] }}
          onOpen={() => undefined}
        />
      </div>
      <div data-meta-row="background-task">
        <IncomingNotice text="Background build finished" />
      </div>
      <div data-meta-row="subsession">
        <SubsessionCallCard call={subsessionCall(start.tool!)} tool={start.tool!} />
      </div>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
