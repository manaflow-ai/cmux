// l10n-allow-file: gallery fixtures, not shipped UI.
// A question the agent asked the person, after another agent's message opened a new turn (Leo,
// 2026-11-06: "we want to keep these things rendered, and perhaps persistent at the bottom, or
// perhaps at the side"). Four looks for where it waits:
// - pinned (shipped): the card in the asks stack above the composer, under "Needs your input" with
//   Dismiss, where the live question card already waits; the card in its turn stays answerable.
// - side: a card in a side column beside the transcript.
// - inline: the card only where it was asked, above the turns that came after.
// - resurfaced: the card again at the transcript's end, under the newest turn.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { nextStepAsk } from "./nextStepAsk";
import { NextStepCard } from "./NextStepCard";
import { PendingAsks } from "./PendingAsks";

type Look = "pinned" | "side" | "inline" | "resurfaced";
type Props = { look: Look; two?: boolean };

const ASKED =
  "The lock screen pauses the capture session, not acpmux.\n\n[taste] Do you mean computer use, still working while the Mac is locked?";
const LATER = "Pushed the CI fix.\n\n[outward] Should I post the gallery on the PR?";
const ask = nextStepAsk(ASKED)!;
const later = nextStepAsk(LATER)!;
const card = (at: number, a = ask): AcpmuxRow =>
  ({ id: `nextStep-${at}`, version: 1, at, kind: "nextStep", nextStep: { ask: a } }) as AcpmuxRow;

const Prose = ({ children }: { children: string }) => (
  <p style={{ margin: 0, color: "var(--agent-text)" }}>{children}</p>
);
const Inbound = ({ from, text }: { from: string; text: string }) => (
  <p style={{ margin: 0, color: "var(--agent-muted)" }}>
    <strong style={{ color: "var(--agent-soft)" }}>{from}</strong> {text}
  </p>
);
const Composer = () => (
  <div
    style={{
      minHeight: 44,
      borderRadius: "var(--ds-radius-popup)",
      border: "0.5px solid var(--agent-border)",
      background: "var(--agent-input-bg)",
      color: "var(--agent-muted)",
      padding: "var(--ds-space-3)",
      boxSizing: "border-box",
    }}
  >
    Message
  </div>
);
const noop = () => Promise.resolve();

function PendingAskInPane({ look, two = false }: Props) {
  const asks = two ? [card(1), card(2, later)] : [card(1)];
  const transcript = (
    <div style={{ display: "flex", flexDirection: "column", gap: 12, minWidth: 0, flex: 1 }}>
      <Prose>{ask.rest}</Prose>
      <NextStepCard ask={ask} onAnswer={noop} />
      <Inbound from="ci-lane" text="Pushed abc123; the focused checks are running." />
      <Prose>Noted. I'll wait for the run.</Prose>
      {two && (
        <>
          <Inbound from="gallery-lane" text="Gallery is ready for the PR." />
          <Prose>{later.rest}</Prose>
          <NextStepCard ask={later} onAnswer={noop} />
          <Inbound from="ci-lane" text="Checks are green." />
          <Prose>Good, that unblocks the merge.</Prose>
        </>
      )}
      {look === "resurfaced" &&
        asks.map((row) => <NextStepCard key={row.id} ask={row.nextStep!.ask} onAnswer={noop} />)}
    </div>
  );
  return (
    <div
      className="acpmux-shell"
      data-pending-ask-look={look}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      {look === "side" ? (
        <div style={{ display: "flex", gap: 16, alignItems: "flex-start" }}>
          {transcript}
          <aside style={{ width: 240, flex: "none", display: "flex", flexDirection: "column", gap: 8 }}>
            <PendingAsks asks={asks} onAnswer={noop} onDismiss={() => undefined} />
          </aside>
        </div>
      ) : (
        transcript
      )}
      {look === "pinned" && (
        <div className="acpmux-permission acpmux-asks-stack" style={{ padding: 0 }}>
          <PendingAsks asks={asks} onAnswer={noop} registerKey={() => () => undefined} onDismiss={() => undefined} />
        </div>
      )}
      <Composer />
    </div>
  );
}

const variant = (look: Look, note: string, two = false) => ({ note, props: { look, two } });

export default componentEntry({
  id: "agent-pane.pending-ask",
  title: "Agent pane: a question to the person after another agent's turn",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".acpmux-next-step" }],
  covers: ["agent-session/acpmux/conversation/PendingAsks.tsx#PendingAsks"],
  styles: () => Promise.all([import("../styles.css"), import("../bottomStack.css"), import("./PendingAsks.css")]),
  load: async () => PendingAskInPane,
  variants: {
    pinned: variant(
      "pinned",
      "Shipped: pinned in the asks stack above the composer, where the live question card waits; the card in its turn stays too.",
    ),
    "pinned-two": variant("pinned", "Shipped: two questions wait, oldest first; the newest takes ⌘↩.", true),
    side: variant("side", "Alternative: a card in a side column beside the transcript."),
    "side-two": variant("side", "Alternative: two questions in the side column.", true),
    inline: variant("inline", "Alternative: the card only where it was asked, above the turns after it."),
    resurfaced: variant("resurfaced", "Alternative: the card again at the transcript's end, under the newest turn."),
  },
});
