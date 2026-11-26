// l10n-allow-file: harness fixtures.
// A prompt's footer on RowFrame's slots (RowSlots.tsx), drawn with the pane's own CSS: prompts still
// on their way (their delivery note under the bubble's text) with a short and a long text, and the
// same prompts landed. The test reads where the end slot's buttons are drawn.
import { createRoot } from "react-dom/client";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { UserBubble } from "../../src/agent-session/acpmux/conversation/UserBubble";
import { TurnActionsContext } from "../../src/agent-session/acpmux/conversation/turnActions";
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

document.body.style.margin = "0";
createRoot(document.getElementById("root")!).render(
  <TurnActionsContext.Provider value={{}}>
    {/* Rows are placed absolutely, as the virtualized transcript places them, each in MessageRow's
        `.cv-user` column, so the footer is laid as in the pane (under the bubble, at its right edge). */}
    <div style={{ position: "relative", width: 640, height: 720 }}>
      {rows.map((row, index) => (
        <article key={row.id} className="acpmux-row acpmux-user" data-testid={row.id} style={{ top: index * 160 }}>
          <div className="cv-user">
            <UserBubble row={row} text={row.text ?? ""} />
          </div>
        </article>
      ))}
    </div>
  </TurnActionsContext.Provider>,
);
requestAnimationFrame(() => requestAnimationFrame(() => (document.documentElement.dataset.harnessReady = "true")));
