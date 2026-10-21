// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A reply's Markdown table (TableBlock.tsx): columns as wide as their text, an empty top-left
// corner labeling the rows, and Open and Copy over its corner on hover.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

// The reply Leo saw (2026-10-20): its first column has no header, and the table spanned the column.
const audit = `**The tooltip audit** found 321 tooltips in the app:

| | Count |
| --- | --- |
| Dropping as useless | 91 |
| Keeping, getting the styled look | 22 |
| Keeping as they are | the rest |`;

const aligned = `Retries by failure:

| Failure | Retried | Backoff | Notes |
| :--- | :---: | ---: | --- |
| 5xx | yes | 250 ms | Up to three tries, doubling each time, then the error goes to the caller as it came. |
| Timeout | yes | 500 ms | Same budget as a 5xx. |
| 4xx | no | 0 ms | A client error repeats the same way. |`;

const snapshot = chat([
  user("How many tooltips are left?", 5),
  assistant(audit, 4.9),
  summary(4.9, { status: "completed", durationMs: 12_000 }),
  user("And the retry table?", 4),
  assistant(aligned, 3.9),
  summary(3.9, { status: "completed", durationMs: 8_000 }),
]);

export default agentPaneEntry({
  id: "agent-pane.table-block",
  title: "Reply tables",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/TableBlock.tsx"],
  variants: {
    rest: {
      note: "Columns fit their text; the table with an empty corner labels its rows.",
      snapshot,
    },
    hover: {
      note: "Hovering a table shows Open and Copy over its top right corner.",
      snapshot,
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
  },
});
