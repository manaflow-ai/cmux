// l10n-allow-file: gallery fixtures (a prompt and a reply), not shipped UI.
// A finished turn's action row hidden at rest and shown on hover, as Claude Code desktop's (Leo,
// 2026-11-22: "claude hides buttons until you hover over the relevant area of a turn response. they
// do a SUPER FAST fade in and fade out for it ... and you hover and you get the timing" and "i think we
// go with claude code here. idk when we decided to always show all buttons always. let's not").
// Variants: at rest (nothing but the reply), the pointer on the turn (the buttons, then its age), a
// key inside the row (same row, Copy's ring), and a failed turn, whose Retry stays shown at rest.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

type Props = { failed?: boolean };

const footer: AcpmuxRow = {
  id: "summary-1",
  version: 1,
  at: minutesAgo(4),
  kind: "turnSummary",
  status: "completed",
  durationMs: 42_000,
  text: "Done: three tries, doubling from 200 ms, only on 5xx and timeouts.",
  retryable: true,
  prompt: "Add retry with backoff to the uploader",
  retryRowId: "user-1",
  seq: 2,
};

const pointTurn: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-turnSummary" });
};
const keyToCopy: Play = async (ctx) => {
  await ctx.focus({ selector: ".cv-turn-actions .cv-iconbtn" });
};

export default componentEntry<Props>({
  id: "agent-pane.turn-actions-hover-reveal",
  title: "Turn action row: hidden at rest, shown on hover with its age",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 360, normal: 620 },
  anchors: [{ selector: ".cv-turn-actions" }],
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx", "agent-session/acpmux/conversation/conversation.css"],
  load: async () => {
    const { TurnFooter } = await import("./TurnRows");
    const { TurnActionsContext } = await import("./turnActions");
    const actions = { retry: () => {}, fork: () => {}, forkSeq: 2 };
    return function GalleryTurnActionsHoverReveal({ failed }: Props) {
      const row = failed ? { ...footer, status: "failed" as const, error: "The request failed." } : footer;
      return (
        <TurnActionsContext.Provider value={actions}>
          <div style={{ padding: "24px 24px 0" }}>
            <div className="acpmux-row acpmux-turnSummary" style={{ position: "relative", contain: "layout" }}>
              <TurnFooter row={row} />
            </div>
          </div>
        </TurnActionsContext.Provider>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "at-rest": {
      note: "No pointer on the turn: the row is hidden, its line kept so nothing moves when it shows.",
      props: {},
    },
    pointed: {
      note: "The pointer on the turn: Copy, Fork, Pin, Timeline, Read aloud and More fade in fast, then the reply's age.",
      props: {},
      play: pointTurn,
    },
    keyboard: {
      note: "A key reached Copy: the row and its age show, as on hover; a stale click focus does not hold it.",
      props: {},
      play: keyToCopy,
    },
    failed: {
      note: "A failed turn keeps its Retry shown at rest; it draws no age.",
      props: { failed: true },
    },
  },
});
