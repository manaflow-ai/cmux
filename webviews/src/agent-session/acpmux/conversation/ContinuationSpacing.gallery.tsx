// l10n-allow-file: public, deterministic conversation and spacing comparisons.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { assistant, summary, user } from "../../../gallery/fixtures/acpmux";
import { VirtualTranscript } from "../App";
import { turnView } from "./turns";

const rows = turnView(
  [
    assistant("The public fixture is ready.\n\nThe next update comes from this same assistant.", 8, {
      id: "continuation-a",
    }),
    summary(8, { id: "continuation-footer-a", status: "completed" }),
    assistant("The checks passed. The handoff is ready for review.", 7, { id: "continuation-b" }),
    summary(7, { id: "continuation-footer-b", status: "completed" }),
    user("The review is complete.", 6, {
      id: "continuation-peer",
      untyped: true,
      incoming: {
        kind: "message",
        message: { name: "review-agent", text: "The review is complete.", raw: "The review is complete." },
      },
    }),
    assistant("The other agent's report is recorded.", 5, { id: "continuation-c" }),
    summary(5, { id: "continuation-footer-c", status: "completed" }),
    user("Keep the speaker changes easy to see.", 4, { id: "continuation-user" }),
    assistant("The speaker changes keep their full gap.", 3, { id: "continuation-d" }),
    summary(3, { id: "continuation-footer-d", status: "completed" }),
  ],
  new Set(),
);

type Props = { gap?: string; tucked?: boolean };
function ContinuationSpacing({ gap, tucked }: Props) {
  return (
    <div
      className="acpmux-shell"
      style={
        {
          ...(gap ? { "--cv-continuation-gap": gap } : {}),
          ...(tucked ? { "--cv-meta-gap": "0px" } : {}),
        } as CSSProperties
      }
    >
      <VirtualTranscript
        rows={rows}
        sessionId="continuation-spacing"
        expanded={new Set()}
        onToggleActivity={() => {}}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.continuation-spacing",
  title: "Same assistant, closer next turn",
  area: "Agent pane",
  height: 760,
  pane: true,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  load: async () => ContinuationSpacing,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    shipped: {
      props: {},
      note: "Selected: half the turn gap (the shared 8px message gap); speaker changes keep 16px.",
    },
    "two-thirds": {
      props: { gap: "calc(var(--cv-turn-gap) * 2 / 3)" },
      note: "Two thirds: more separation, but the continuation still feels like a new speaker.",
    },
    "half-tucked": {
      props: { tucked: true },
      note: "Half gap with the footer tucked against the answer: denser, but the controls crowd the text.",
    },
    before: {
      props: { gap: "var(--cv-turn-gap)" },
      note: "Before: the same assistant's next turn keeps the full 16px gap.",
    },
  },
});
