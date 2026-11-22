// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A reply's Markdown table (TableBlock.tsx): columns as wide as their text and no wider than the
// column, cells that wrap, an empty top-left corner labeling the rows, and Open and Copy on the
// table's own top-right corner on hover. The experiment's arms (tableActions.experiment.ts) put
// that pair in the corner, above it or beside it; `corner` ships.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { tableActionsPlace } from "./tableActions.experiment";
import { TABLE_AFTER_BOLD } from "./tableAfterParagraph.fixture";

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

// A reply that opens with a wide table: at chat width its prose columns wrap and it fits.
const wide = `| Check | Base | Head | Change | Runner | Notes |
| --- | ---: | ---: | ---: | --- | --- |
| webviews check | 41 s | 43 s | +2 s | linux-8 | Oxlint, Oxfmt and the type check in one pass. |
| bun test | 2 m 10 s | 2 m 12 s | +2 s | linux-8 | The browser lane runs separately. |`;

// The status table Leo saw clipped mid-word (2026-11-05), with its actions far off to the right:
// three columns, two of them long prose, in a reply at chat width.
const status = `Here. Nothing has merged since my last update, and four PRs are still open:

| PR | What it is | Where it's at |
|---|---|---|
| #36918 | Hosted Ubuntu for declared light jobs, clearing \`main\`'s four red checks | Passed review and is merging. The merge hasn't gone through yet. |
| #36846 | Cloud chat sign-in fix | Still at \`563db483\`. The helper is writing the three ownership states, the server fix and the new tests. No new head has been pushed. |
| #36933 | Pin for the Cloud desktop image | Waiting on checks. Then come the image bake, the prod image switch and the desktop probe. |
| #36869 | Combined test branch | On HOLD. It gets rebuilt on #36846's new head, and nothing is built until then. |

**Still not working end to end:** a Cloud chat started on a fresh machine.`;

const statusChat = chat([
  user("Where are we?", 2),
  assistant(status, 1.9),
  summary(1.9, { status: "completed", durationMs: 46_000 }),
]);

// Paths and hashes: paths break at their slashes, so this fits a chat column; a token wider than
// the column is the only thing that scrolls a table sideways, with a fade at the edge.
const unbreakable = `| File | Head |
| --- | --- |
| webviews/src/agent-session/acpmux/conversation/TableBlock.tsx | 0e8648b1ba0c67d0be0123a61d7772ad05cc9deb |
| webviews/src/agent-session/acpmux/conversation/conversation.css | 4115c9aa1f29ac24d44ed188117dea29a2321c91 |`;

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
      note: "Hovering a table shows same-size Open and Copy controls on one centered line on its own top-right corner.",
      snapshot: chat([
        user("How many tooltips are left?", 5),
        assistant(audit, 4.9),
        summary(4.9, { status: "completed", durationMs: 12_000 }),
      ]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
    status: {
      note: "Three columns, two of prose, at chat width: every cell wraps inside the column, and nothing clips.",
      snapshot: statusChat,
    },
    "status-hover": {
      note: "The same table hovered: Open and Copy sit on its own top-right corner.",
      snapshot: statusChat,
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
    "first-block": {
      note: "A reply that opens with a six-column table: its prose wraps so it fits, and Open and Copy stay on its corner.",
      snapshot: chat([
        user("CI times?", 2),
        assistant(wide, 1.9),
        summary(1.9, { status: "completed", durationMs: 5_000 }),
      ]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
    "after-bold": {
      note: "Leo's reply (2026-11-08): a table on the line right under a bold line, with no blank line between them, draws as a table of 4 columns and 8 rows, as GFM reads it, never as raw pipe lines.",
      snapshot: chat([
        user("Where are the cloud goals?", 2),
        assistant(TABLE_AFTER_BOLD, 1.9),
        summary(1.9, { status: "completed", durationMs: 31_000 }),
      ]),
    },
    unbreakable: {
      note: "Paths break at their slashes and hashes fit: the table stays in the column. Only a wider token scrolls it, with a fading edge.",
      snapshot: chat([
        user("Which heads?", 2),
        assistant(unbreakable, 1.9),
        summary(1.9, { status: "completed", durationMs: 5_000 }),
      ]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-table-block" });
      },
    },
  },
  experiment: {
    definition: tableActionsPlace,
    script: [
      {
        name: "Hover the table",
        run: async (ctx) => {
          await ctx.hover({ selector: ".cv-table-block" });
        },
      },
    ],
  },
});
