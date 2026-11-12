// l10n-allow-file: gallery fixtures (sample recaps and prompts), not shipped UI.
// The session recap row (RecapNote.tsx). Leo, 2026-11-12: "and also a gui enableable recap
// feature", pointing at Claude Code's terminal line "※ recap: The goal is ... Next, I'll ...". Three
// looks of that quiet italic line (terminal, shipped; plain; mark) beside the earlier hairline card
// after Claude's own recap card (cmux-design-references claude/web/october-recap-card), a tool-row
// line and a left rule. A compact row, never a user or assistant bubble.
import { componentEntry } from "../../../gallery/format";
import { RecapNote, type RecapLook } from "./RecapNote";

const SHORT =
  "The goal is to make the parser in foo.rs tolerate missing fields. Next, I'll open foo.rs and see how absent fields fail.";
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

export default componentEntry<{ look: RecapLook; readOnly?: boolean }>({
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
    terminal: {
      note: 'Chosen: Claude Code\'s own line, "※ recap:" then the text, all italic in the dim text color, the × showing on hover or focus. Reads as a margin note, quietest of the looks that still name themselves.',
      props: { look: "terminal" },
    },
    plain: {
      note: "The italic line with no lead: quietest, but a lone italic sentence mid-transcript can read as the agent's own aside.",
      props: { look: "plain" },
    },
    mark: {
      note: "The ※ alone as the lead: compact, but the mark means nothing to someone who never saw the terminal's line.",
      props: { look: "mark" },
    },
    card: {
      note: "The earlier look: a hairline card with a ×, as Claude's own recap card; heavier than the terminal's line.",
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
    "read-only": {
      note: "A shared chat's guest or a replay: the line with no ×, which would do nothing there.",
      props: { look: "terminal", readOnly: true },
    },
  },
});
