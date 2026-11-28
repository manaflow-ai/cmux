// l10n-allow-file: harness fixtures.
// A prompt's footer on RowFrame's slots (RowSlots.tsx), drawn with the pane's own CSS: prompts still
// on their way (their delivery note under the bubble's text) with a short and a long text, and the
// same prompts landed. The test reads where the end slot's buttons are drawn. The other kinds that draw
// actions on their line, each with a short and a long text: another agent's message (its hover row,
// AgentMessageRow.tsx) and a notice line (DisclosureRow.tsx `actions`).
import { createRoot } from "react-dom/client";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { UserBubble } from "../../src/agent-session/acpmux/conversation/UserBubble";
import { TurnActionsContext } from "../../src/agent-session/acpmux/conversation/turnActions";
import { IncomingMessageLine } from "../../src/agent-session/acpmux/conversation/IncomingMessageCard";
import { DisclosureRow } from "../../src/agent-session/acpmux/subagents/DisclosureRow";
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

const SHORT = "Ship it";
const LONG = "Rebase onto the base branch first, then run the whole suite and ship it once it is green";
// On its way for a minute: past the note's delay (PromptDelivery.tsx `usePendingShown`).
const sending = { state: "sending", promptId: "p", sessionId: "s", sentAt: Date.now() - 60_000 } as const;
const prompt = (id: string, text: string, pending: boolean): AcpmuxRow =>
  ({
    id,
    version: 1,
    at: Date.now(),
    kind: "user",
    seq: 1,
    text,
    ...(pending ? { delivery: { ...sending, promptId: id } } : {}),
  }) as AcpmuxRow;

const rows = [
  prompt("pending-short", SHORT, true),
  prompt("pending-long", LONG, true),
  prompt("landed-short", SHORT, false),
  prompt("landed-long", LONG, false),
];

const message = (text: string) => ({ name: "review-lane", sessionId: "lane-1", text, raw: text });
const received = (id: string, text: string) => (
  <IncomingMessageLine id={id} message={message(text) as never} onOpen={() => {}} />
);
const notice = (text: string) => (
  <DisclosureRow
    className="cv-received cv-lane-notice"
    label={<span className="cv-received__preview">{text}</span>}
    actions={
      <span className="cv-received__hover">
        <button type="button" className="cv-copy-button">
          Copy
        </button>
      </span>
    }
  >
    {text}
  </DisclosureRow>
);
const lines = [
  { id: "received-short", node: received("received-short", SHORT) },
  { id: "received-long", node: received("received-long", LONG) },
  { id: "notice-short", node: notice(SHORT) },
  { id: "notice-long", node: notice(LONG) },
];

document.body.style.margin = "0";
createRoot(document.getElementById("root")!).render(
  <TurnActionsContext.Provider value={{}}>
    {/* Rows are placed absolutely, as the virtualized transcript places them, each in MessageRow's
        `.cv-user` column, so the footer is laid as in the pane (under the bubble, at its right edge). */}
    <div style={{ position: "relative", width: 640, height: 1000 }}>
      {rows.map((row, index) => (
        <article key={row.id} className="acpmux-row acpmux-user" data-testid={row.id} style={{ top: index * 160 }}>
          <div className="cv-user">
            <UserBubble row={row} text={row.text ?? ""} />
          </div>
        </article>
      ))}
      {lines.map((line, index) => (
        <div key={line.id} className="acpmux-row" data-testid={line.id} style={{ top: 680 + index * 60 }}>
          {line.node}
        </div>
      ))}
    </div>
  </TurnActionsContext.Provider>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (document.documentElement.dataset.harnessReady = "true")));
