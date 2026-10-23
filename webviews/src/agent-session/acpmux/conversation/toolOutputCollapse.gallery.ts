// l10n-allow-file: gallery fixtures (sample prompts, commands and tool output), not shipped UI.
// Long tool outputs (ToolRow.tsx, ShellBlock.tsx, BlockParts.tsx; Leo 2026-10-22: "also the tool
// calling i think there should be more of like a "show more" type thing for long outputs or
// whatnot..."): an opened call's output and a command's Shell block show their first rows under a
// fade, then a control that opens them in place, and Show less closes them again. A block of many
// lines says "Show all N lines"; one of a few lines that wrap to many rows (a one-line JSON
// result) says "Show more". Compare arms shows the `tool-output-collapse` experiment's looks.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxActivity } from "../model";
import type { PlayContext } from "../../../gallery/play";
import { toolOutputCollapse } from "./toolOutputCollapse.experiment";

const times = (at: number) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - 0.02) });

/// One call in a working turn, with the agent's note after it, so it draws as its own row.
const oneCall = (prompt: string, call: AcpmuxActivity, note: string) =>
  chat([user(prompt, 6), activity([call], 5.8), assistant(`${note}\n\nOn to the next step.`, 5.7)], {
    isWorking: true,
  });

/// A fetch that returned one line of JSON, about 2,400 characters: it wraps to many rows.
const ONE_LINE_JSON = JSON.stringify({
  data: Array.from({ length: 40 }, (_, index) => ({
    id: `item-${index + 1}`,
    status: index % 7 === 3 ? "retrying" : "ok",
    attempts: 1 + (index % 3),
  })),
  next: null,
});

const jsonCall = oneCall(
  "Check what the items endpoint returns",
  tool("Fetch https://api.example.test/v2/items", "fetch", "completed", { output: ONE_LINE_JSON, ...times(5.8) }),
  "Two items are still retrying.",
);

/// A test run of forty lines.
const LOG = Array.from({ length: 40 }, (_, index) => `(pass) retry backoff case ${index + 1} [0.${index % 10}ms]`).join(
  "\n",
);

const logCall = oneCall(
  "Run the retry tests",
  tool("bun test src/net --filter retry", "execute", "completed", {
    command: "bun test src/net --filter retry",
    output: `${LOG}\n\n 40 pass\n 0 fail`,
    exitCode: 0,
    ...times(5.8),
  }),
  "All forty retry cases pass.",
);

const shortCall = oneCall(
  "Run the focused test",
  tool("bun test src/net/retry.test.ts", "execute", "completed", {
    command: "bun test src/net/retry.test.ts",
    output: " 3 pass\n 0 fail",
    exitCode: 0,
    ...times(5.8),
  }),
  "The focused test passes.",
);

/// Opens the call, to show its output under it.
const openCall = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".cv-tool.is-toggle" });
  await ctx.waitFor(() => ctx.find({ selector: ".cv-tool.is-toggle" }).getAttribute("aria-expanded") === "true");
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-tool-output, .cv-shell__body")));
};

/// Waits for the output's control to read `label`.
const control = (ctx: PlayContext, label: string | RegExp) =>
  ctx.waitFor(() => {
    const text = ctx.document.querySelector(".cv-output-more")?.textContent ?? "";
    return typeof label === "string" ? text === label : label.test(text);
  });

/// Opens the call, then its output with Show more or Show all N lines.
const expand = async (ctx: PlayContext) => {
  await openCall(ctx);
  await ctx.click({ selector: ".cv-output-more" });
  await control(ctx, "Show less");
};

export default agentPaneEntry({
  id: "agent-pane.tool-output-collapse",
  title: "Tool output collapse",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/BlockParts.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  keywords: ["show more", "show less", "collapse", "long output", "tool output", "preview"],
  variants: {
    "wrapped-collapsed": {
      note: "A fetch's one-line JSON result wraps to many rows: its first eight under a fade, with Show more.",
      snapshot: jsonCall,
      play: async (ctx) => {
        await openCall(ctx);
        await control(ctx, "Show more");
      },
    },
    "wrapped-expanded": {
      note: "Show more opens the whole result in place and turns into Show less.",
      snapshot: jsonCall,
      play: expand,
    },
    "lines-collapsed": {
      note: "A command of forty lines: its first eight under a fade, with Show all 44 lines.",
      snapshot: logCall,
      play: async (ctx) => {
        await openCall(ctx);
        await control(ctx, /^Show all \d+ lines$/);
      },
    },
    "lines-expanded": {
      note: "Show all 44 lines opens every line in place and turns into Show less.",
      snapshot: logCall,
      play: expand,
    },
    short: {
      note: "An output that fits shows whole, with no control.",
      snapshot: shortCall,
      play: openCall,
    },
  },
  experiment: {
    definition: toolOutputCollapse,
    script: [
      { name: "open the call", run: openCall },
      {
        name: "show more",
        run: async (ctx) => {
          await ctx.click({ selector: ".cv-output-more" });
          await control(ctx, "Show less");
        },
      },
    ],
  },
});
