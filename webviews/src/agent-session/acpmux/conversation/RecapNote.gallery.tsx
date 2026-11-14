// l10n-allow-file: gallery fixtures (sample recaps and prompts), not shipped UI.
// The session recap row (RecapNote.tsx) in three looks beside Claude's own recap card
// (cmux-design-references claude/web/october-recap-card): a hairline card with a × (shipped), a
// tool-row line and a left rule. A compact row, never a user or assistant bubble.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { oneRecap } from "./oneRecap";
import { RecapNote, type RecapLook } from "./RecapNote";

const SHORT =
  "Goal: make the parser in foo.rs tolerate missing fields. Next: open foo.rs and see how absent fields fail.";
const LONG =
  "We're moving the Cloud machine resize onto the platform API so a busy chat never waits on it; the API route and its tests are in. Next: wire the app's resize button to the new route and check a real resize end to end.";

function RecapLooks({ look, readOnly = false }: { look: RecapLook; readOnly?: boolean }) {
  const onDismiss = readOnly ? undefined : () => {};
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16 }}>
      <RecapNote
        recap={{ key: `gallery-short-${look}`, text: SHORT, awayMs: 6 * 60_000 }}
        onDismiss={onDismiss}
        look={look}
      />
      <RecapNote
        recap={{ key: `gallery-long-${look}`, text: LONG, awayMs: 42 * 60_000 }}
        onDismiss={onDismiss}
        look={look}
      />
    </div>
  );
}

/// A chat logged before acpmux kept one recap per chat: eight returns, eight recaps of the same
/// facts. Drawn through oneRecap.ts, only the newest shows.
const STACK = [
  "The Chief CSS design-system batch is finished: #34338, the surface map #34349 and the spec updates are all merged.",
  "The Chief CSS design-system batch is finished and merged (#34338, #34349). The lane folder isn't on this machine.",
  "Chief CSS batch 8 is landed: #34338 and #34349 are merged. Next: send the restart to the right lane.",
  "The goal was moving the Chief pages' CSS onto the design system; that's merged (#34338, #34349). Next: find where the lane lives.",
];

function OnePerChat() {
  const rows: AcpmuxRow[] = STACK.map((text, n) => ({
    id: `recap-${n + 1}`,
    version: 1,
    at: n,
    kind: "recap",
    recap: { key: `gallery-chat:${n + 1}`, text },
  }));
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16 }}>
      {oneRecap(rows, () => []).map((row) =>
        row.recap ? <RecapNote key={row.id} recap={row.recap} onDismiss={() => {}} /> : null,
      )}
    </div>
  );
}

export default componentEntry<{ look: RecapLook; readOnly?: boolean; stack?: boolean }>({
  id: "agent-pane.recap-note",
  title: "Session recap row",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/RecapNote.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => (props: { look: RecapLook; readOnly?: boolean; stack?: boolean }) =>
    props.stack ? <OnePerChat /> : <RecapLooks {...props} />,
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
    "one-per-chat": {
      note: "A chat with a recap from each of four returns, all saying the same thing: one card, the newest.",
      props: { look: "card", stack: true },
    },
    "read-only": {
      note: "A shared chat's guest or a replay: the card with no ×, which would do nothing there.",
      props: { look: "card", readOnly: true },
    },
  },
});
