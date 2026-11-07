// l10n-allow-file: harness fixtures.
// Another agent's messages on the one message row (AgentMessageRow.tsx), drawn with the pane's own
// CSS: a waiting group of two messages from one sender, opened (PendingMessagesCard.tsx), and one
// received message opened, its card's corner copy in it (CardCopy.tsx). The test reads computed
// styles: the CSS that once named the old DisclosureRow classes must reach the new rows.
import { createRoot } from "react-dom/client";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { IncomingMessageLine } from "../../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { PendingMessagesCard } from "../../src/agent-session/acpmux/conversation/PendingMessagesCard";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";

const message = (text: string) => ({ name: "release-rings-32", sessionId: "lane-1", text, raw: text });
const waiting = (id: string, text: string) =>
  ({ id, kind: "incoming", incoming: { kind: "message", message: message(text) } }) as unknown as AcpmuxRow;
const group = {
  id: "pending-group",
  pendingMessages: { rows: [waiting("w-1", "First waiting message"), waiting("w-2", "Second waiting message")] },
} as unknown as AcpmuxRow;

const draw = (row: AcpmuxRow) => {
  const incoming = row.incoming?.kind === "message" ? row.incoming.message : undefined;
  return incoming && <IncomingMessageLine id={row.id} message={incoming as never} onOpen={() => {}} />;
};

document.body.style.margin = "0";
createRoot(document.getElementById("root")!).render(
  // Rows are placed absolutely, as the virtualized transcript places them.
  <div style={{ position: "relative", width: 640, height: 600 }}>
    <div className="acpmux-row" data-testid="pending" style={{ top: 0 }}>
      <PendingMessagesCard row={group} onOpen={() => {}} renderMessage={draw} />
    </div>
    <div className="acpmux-row" data-testid="received" style={{ top: 300 }}>
      {draw(waiting("r-1", "A received message\n\nwith a second paragraph"))}
    </div>
  </div>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (document.documentElement.dataset.harnessReady = "true")));
