// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A reply's Markdown table (TableBlock.tsx): columns as wide as their text, an empty top-left
// corner labeling the rows, and Open and Copy aligned at its top-right corner on hover.
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

// A reply that opens with a wide table (one wider than the column scrolls): its buttons keep their room.
const wide = `| Check | Base | Head | Change | Runner | Notes |
| --- | ---: | ---: | ---: | --- | --- |
| webviews check | 41 s | 43 s | +2 s | linux-8 | Oxlint, Oxfmt and the type check in one pass. |
| bun test | 2 m 10 s | 2 m 12 s | +2 s | linux-8 | The browser lane runs separately. |`;

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
  height: 640,
  covers: ["agent-session/acpmux/conversation/TableBlock.tsx"],
  variants: {
    rest: {
      note: "Columns fit their text; the table with an empty corner labels its rows.",
      snapshot,
    },
    hover: {
      note: "Hovering a table shows same-size Open and Copy controls on one centered line at its top-right corner.",
      snapshot: chat([
        user("How many tooltips are left?", 5),
        assistant(audit, 4.9),
        summary(4.9, { status: "completed", durationMs: 12_000 }),
      ]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
    "first-block": {
      note: "A reply that opens with a wide table: the top-right Open and Copy pair stays aligned while the table scrolls.",
      snapshot: chat([
        user("CI times?", 2),
        assistant(wide, 1.9),
        summary(1.9, { status: "completed", durationMs: 5_000 }),
      ]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
  },
});
