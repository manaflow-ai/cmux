// l10n-allow-file: gallery fixtures (sample recaps and prompts), not shipped UI.
// The session recap row (RecapNote.tsx) in three looks beside Claude's own recap card
// (cmux-design-references claude/web/october-recap-card): a hairline card with a × (shipped), a
// tool-row line and a left rule. A compact row, never a user or assistant bubble.
import { componentEntry } from "../../../gallery/format";
import { RecapNote, type RecapLook } from "./RecapNote";

const SHORT =
  "Goal: make the parser in foo.rs tolerate missing fields. Next: open foo.rs and see how absent fields fail.";
const LONG =
  "We're moving the Cloud machine resize onto the platform API so a busy chat never waits on it; the API route and its tests are in. Next: wire the app's resize button to the new route and check a real resize end to end.";

function RecapLooks({ look }: { look: RecapLook }) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16 }}>
      <RecapNote
        recap={{ key: `gallery-short-${look}`, text: SHORT, awayMs: 6 * 60_000 }}
        onDismiss={() => {}}
        look={look}
      />
      <RecapNote
        recap={{ key: `gallery-long-${look}`, text: LONG, awayMs: 42 * 60_000 }}
        onDismiss={() => {}}
        look={look}
      />
    </div>
  );
}

export default componentEntry<{ look: RecapLook }>({
  id: "agent-pane.recap-note",
  title: "Session recap row",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/RecapNote.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => RecapLooks,
  variants: {
    card: {
      note: "Chosen: a hairline card with a ×, as Claude's own recap card; muted text, the lead-in in the body color.",
      props: { look: "card" },
    },
    line: {
      note: "A tool-row line in the transcript's step column; quieter, but reads as one more tool step and its × floats.",
      props: { look: "line" },
    },
    rule: {
      note: "A left rule like a quote; reads as quoted text from someone else.",
      props: { look: "rule" },
    },
  },
});
