// l10n-allow-file: harness fixtures.
// Another agent's messages on the one message row (AgentMessageRow.tsx), drawn with the pane's own
// CSS: a waiting group of two messages from one sender, opened (PendingMessagesCard.tsx), and one
// received message opened, its card's corner copy in it (CardCopy.tsx), and two sent messages
// (SentMessageLine.tsx, drawn as received ones on the same row): one to a listed chat, queued, and
// one that failed. The test reads computed styles: the CSS that once named the old
// DisclosureRow classes must reach the new rows.
import { createRoot } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { IncomingMessageLine } from "../../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { PendingMessagesCard } from "../../src/agent-session/acpmux/conversation/PendingMessagesCard";
import { AcpmuxSendLine } from "../../src/agent-session/acpmux/conversation/SentMessageLine";
import { acpmuxSendCall } from "../../src/agent-session/acpmux/conversation/acpmuxSends";
import { SubsessionContext, SubsessionStore } from "../../src/agent-session/acpmux/subagents/subsessions";
import type { AcpmuxSessionEntry } from "../../src/agent-session/acpmux/sessionList";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const message = (text: string, name = "release-rings-32") => ({ name, sessionId: "lane-1", text, raw: text });
const waiting = (id: string, text: string, name?: string) =>
  ({ id, kind: "incoming", incoming: { kind: "message", message: message(text, name) } }) as unknown as AcpmuxRow;
// A first line far wider than the row: it, not the sender's name, gives way (cmux#37653 review).
const LONG =
  "Confirmed. On feat-cmux-next today, the overlay card is as tall as its content and ends 15px under its last section, so no fix needed.";
const group = {
  id: "pending-group",
  pendingMessages: { rows: [waiting("w-1", "First waiting message"), waiting("w-2", "Second waiting message")] },
} as unknown as AcpmuxRow;

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const send = (id: string, command: string, fields: Partial<Tool>): Tool => ({
  id,
  title: command,
  kind: "execute",
  status: "completed",
  command,
  ...fields,
});
const sent = send("send-1", "acpmux send --no-wait review-lane 'Merged; the batch is next.'", {
  output: "queued",
});
const failed = send("send-2", "acpmux send perf-lane 'Profile it.'", {
  status: "failed",
  output: 'Exit code 4\nacpmux: no_session: no session matches "perf-lane"',
});
// The recipient is a listed chat, so its chip is the session link that opens it.
const chats = new SubsessionStore();
chats.set([{ sessionId: "s-review", name: "review-lane" } as AcpmuxSessionEntry]);

const draw = (row: AcpmuxRow) => {
  const incoming = row.incoming?.kind === "message" ? row.incoming.message : undefined;
  return incoming && <IncomingMessageLine id={row.id} message={incoming as never} onOpen={() => {}} />;
};

document.body.style.margin = "0";
createRoot(document.getElementById("root")!).render(
  // Rows are placed absolutely, as the virtualized transcript places them.
  <div style={{ position: "relative", width: 640, height: 680 }}>
    <div className="acpmux-row" data-testid="pending" style={{ top: 0 }}>
      <PendingMessagesCard row={group} onOpen={() => {}} renderMessage={draw} />
    </div>
    <div className="acpmux-row" data-testid="received" style={{ top: 300 }}>
      {draw(waiting("r-1", "A received message\n\nwith a second paragraph"))}
    </div>
    <div className="acpmux-row" data-testid="long-preview" style={{ top: 560 }}>
      {draw(waiting("r-2", LONG, "summary-panel"))}
    </div>
    <SubsessionContext.Provider value={{ store: chats, open: () => {} }}>
      <div className="acpmux-row" data-testid="sent" style={{ top: 600 }}>
        <AcpmuxSendLine tool={sent} send={acpmuxSendCall(sent)!} />
      </div>
      <div className="acpmux-row" data-testid="sent-failed" style={{ top: 640 }}>
        <AcpmuxSendLine tool={failed} send={acpmuxSendCall(failed)!} />
      </div>
    </SubsessionContext.Provider>
  </div>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (document.documentElement.dataset.harnessReady = "true")));
