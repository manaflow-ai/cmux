// l10n-allow-file: gallery fixtures, not shipped UI.
// The pinned "Needs your input" ask over the composer (PendingAsks.tsx). Leo, 2026-11-19, with
// screenshots of a wrap-up ask pinned as "[trust] Trust ~/fun/cmux for the new sub-session?": "odd
// looking". Two fixes in every look: the wrap-up question's leading "[trust]" is a tag chip
// (wrapUp.ts `splitLeadingTag`, NextStepCard.tsx), and the line and the card are one thing.
// References: claude/web/october-recap-card (Claude desktop's next-step box, its × in the corner),
// codex/live/approvals-codex-network-access-review (a title row with × inside the card), and the
// composer hat's own question band (question/hatQuestions.css: mark, tag chip, ×).
// - before: the shipped look until now, "Needs your input" and a Dismiss word on a line over a
//   separate card (a CSS override of the old rules, NeedsInputCardLooks.gallery.css).
// - card (shipped): one stack card, its head row inside: the attention mark, "Needs your input",
//   the shared ×; then the question with its tag chip and the answers.
// - attached: the same card on the composer's edges, flush on its top, the two square where they
//   meet, as the running tray joins the composer (bottomStack.css).
// - compact: one card, the question and the answers on one row (wrapping when narrow).
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { nextStepAsk, type NextStepAsk } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";
import { PendingAsks } from "./PendingAsks";
import { wrapUpAsk } from "./wrapUp";

type Look = "before" | "card" | "attached" | "compact";
type Fixture = "wrap-up" | "tagged" | "both";
type Props = { look: Look; fixture: Fixture };

// The wrap-up from Leo's screenshot: a recap, a "[trust]" question and two answers.
const WRAP_UP = wrapUpAsk({
  title: "mcp__acpmux__wrap_up",
  status: "completed",
  inputSummary: JSON.stringify({
    recap:
      "Started the sub-session in ~/fun/cmux on lane/needs-input-card-polish. It waits for the folder to be trusted before it reads anything.",
    ask: "[trust] Trust ~/fun/cmux for the new sub-session?",
    actions: ["Trust it", "Not now"],
  }),
} as Parameters<typeof wrapUpAsk>[0])!;
// A tagged ask in the prose (nextStepAsk.ts): Yes and Not now.
const TAGGED = nextStepAsk(
  "Ready for review.\n\n[taste] Is 32 px right for the live line in #43627?\nIf yes, it merges at 32 and the value moves to one place.",
)!;

const row = (at: number, ask: NextStepAsk): AcpmuxRow =>
  ({ id: `nextStep-${at}`, version: 1, at, kind: "nextStep", nextStep: { ask } }) as AcpmuxRow;
const ROWS: Record<Fixture, AcpmuxRow[]> = {
  "wrap-up": [row(1, WRAP_UP)],
  tagged: [row(2, TAGGED)],
  both: [row(2, TAGGED), row(3, WRAP_UP)],
};
const noop = () => Promise.resolve();

function NeedsInputInPane({ look, fixture }: Props) {
  const asks = ROWS[fixture];
  const first = asks[0]!.nextStep!.ask;
  return (
    <div
      className="acpmux-shell needs-input-looks"
      data-needs-input-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      <p style={{ margin: 0, color: "var(--agent-text)" }}>{first.rest || "Done."}</p>
      {/* The card where it was asked, recap and tag chip included. */}
      <NextStepCard ask={first} onAnswer={noop} />
      <p style={{ margin: 0, color: "var(--agent-muted)" }}>
        <strong style={{ color: "var(--agent-soft)" }}>ci-lane</strong> Pushed abc123; the focused checks are running.
      </p>
      <div className="needs-input-looks__dock">
        <div className="acpmux-permission acpmux-asks-stack" style={{ padding: 0 }}>
          <PendingAsks asks={asks} onAnswer={noop} registerKey={() => () => undefined} onDismiss={() => undefined} />
        </div>
        <div className="needs-input-looks__composer">Message</div>
      </div>
    </div>
  );
}

const variant = (look: Look, fixture: Fixture, note: string) => ({ note, props: { look, fixture } });

export default componentEntry({
  id: "agent-pane.needs-input-card-looks",
  title: "Agent pane: the pinned Needs your input card, looks",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".acpmux-pending-ask" }],
  covers: [
    "agent-session/acpmux/conversation/PendingAsks.tsx#PendingAsks",
    "agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../bottomStack.css"),
      import("../composerStates.css"),
      import("./PendingAsks.css"),
      import("./NeedsInputCardLooks.gallery.css"),
    ]),
  load: async () => NeedsInputInPane,
  variants: {
    "before-wrap-up": variant("before", "wrap-up", "Before: a line and a Dismiss word over a separate card."),
    "before-tagged": variant("before", "tagged", "Before: a tagged ask."),
    "card-wrap-up": variant(
      "card",
      "wrap-up",
      "Shipped: one card, its head row inside (mark, Needs your input, ×); [trust] is a chip.",
    ),
    "card-tagged": variant("card", "tagged", "Shipped: a tagged ask, Yes and Not now."),
    "card-two": variant("card", "both", "Shipped: two asks wait, oldest first; the newest takes ⌘↩."),
    "attached-wrap-up": variant("attached", "wrap-up", "Alternative: flush on the composer's top, on its edges."),
    "attached-tagged": variant("attached", "tagged", "Alternative: attached, a tagged ask."),
    "compact-wrap-up": variant("compact", "wrap-up", "Alternative: the question and the answers on one row."),
    "compact-tagged": variant("compact", "tagged", "Alternative: compact, a tagged ask."),
  },
});
