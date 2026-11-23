// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// The trajectory view, customizable (Leo, 2026-11-17 standup: "customize trajectory GUI (look into
// [a reference app])"; conversation/trajectory.ts). One finished turn with every kind of step (a
// thought, reads, a search, commands, an edit, an MCP call and a failed command), drawn under each
// setting: `agentPane.display.trajectory.layout`, `.density`, `.grouping` and `.hide`. References:
// a thread timeline that draws one row per step with its glyph, a task timeline that hangs its steps
// on a thin line, and a tool call density setting. The `cards` and `bare` layouts are gallery arms
// only (trajectory.css `data-trajectory-arm`): `rail` is the one the setting offers.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity } from "../model";

const run = (description: string, command: string, fields: Record<string, unknown> = {}): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0, ...fields });
const read = (path: string): AcpmuxActivity =>
  tool(`Read ${path}`, "read", "completed", { locations: [{ path }], output: "…\n" });

function turn() {
  return [
    user("Make the retry banner wait for the network before it retries", 20),
    activity(
      [
        thought("The banner retries on a timer; it should listen for the network coming back instead."),
        read("src/net/retry.ts"),
        read("src/ui/RetryBanner.tsx"),
        tool("Grep onOnline", "search", "completed", { output: "src/net/online.ts:12\n" }),
        run("Ran the retry tests", "bun test retry"),
        tool("Edit src/net/retry.ts", "edit", "completed", {
          diffs: [
            {
              path: "src/net/retry.ts",
              oldText: "setTimeout(retry, 5000);\n",
              newText: "onOnline(retry);\nsetTimeout(retry, 30000);\n",
            },
          ],
        }),
        tool("mcp__repo__repo_grep", "other", "completed", {
          inputSummary: JSON.stringify({ pattern: "RetryBanner" }),
          output: "src/App.tsx:88\n",
        }),
        run("Typechecked the app", "bunx tsc --noEmit", { status: "failed", exitCode: 2, output: "1 error\n" }),
        run("Typechecked it again", "bunx tsc --noEmit"),
        run("Ran the retry tests again", "bun test retry"),
      ],
      12,
    ),
    assistant(
      "The banner now waits for the network to come back, and still retries every 30 seconds as a fallback.",
      6,
    ),
    summary(5.8, { status: "completed", durationMs: 96_000, toolCount: 9 }),
  ];
}

function snapshot() {
  const base = chat(turn(), { title: "Retry banner waits for the network", harness: "claude" });
  return { ...base, summary: { ...base.summary!, family: "claude" } };
}

/// Opens the turn's "Worked for" line, so its steps show.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (
  note: string,
  display: Record<string, unknown> = {},
  documentAttributes?: Record<string, string>,
): AgentPaneVariant => ({
  note,
  snapshot: snapshot(),
  display,
  ...(documentAttributes ? { documentAttributes } : {}),
  play: openWorked,
});

const RAIL = { "agentPane.display.trajectory.layout": "rail" };
const SEPARATE = { "agentPane.display.trajectory.grouping": "separate" };

export default agentPaneEntry({
  id: "agent-pane.trajectory",
  title: "Trajectory view: layout, density, grouping and hidden steps",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/trajectory.ts",
    "agent-session/acpmux/conversation/trajectory.css",
    "agent-session/acpmux/conversation/toolGroups.ts",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
  ],
  keywords: ["trajectory", "steps", "timeline", "rail", "density", "compact", "group", "hide", "customize"],
  variants: {
    default: variant("No trajectory setting: the transcript as it ships, runs of one kind under one line."),
    rail: variant(
      "Chosen layout, `layout: rail`: every step on its own row, each glyph hung on one thin line down the icon column, as a task timeline.",
      { ...RAIL, ...SEPARATE },
    ),
    "rail-grouped": variant("`layout: rail` with the default grouping: the line joins the run lines.", RAIL),
    cards: variant(
      "Arm, not offered: each step in a hairline card, as a detailed tool call density. Heavy for a long turn.",
      SEPARATE,
      { "trajectory-arm": "cards" },
    ),
    bare: variant(
      "Arm, not offered: no glyphs, the words on the prose edge, as Claude Code. Loses the icon column.",
      SEPARATE,
      { "trajectory-arm": "bare" },
    ),
    compact: variant("`density: compact`: 20px rows, every step on its own row.", {
      ...SEPARATE,
      "agentPane.display.trajectory.density": "compact",
    }),
    relaxed: variant("`density: relaxed`: 26px rows on the timeline.", {
      ...RAIL,
      ...SEPARATE,
      "agentPane.display.trajectory.density": "relaxed",
    }),
    separate: variant("`grouping: separate`: every call on its own row, no run folded.", SEPARATE),
    "hide-routine": variant(
      "`hide: [thinking, reads, searches]`: only what changed things shows. The failed typecheck stays: a failed step always shows.",
      { ...SEPARATE, "agentPane.display.trajectory.hide": ["thinking", "reads", "searches"] },
    ),
    "hide-commands": variant("`hide: [commands, tools]`: the failed typecheck still shows; the edit and reads stay.", {
      ...SEPARATE,
      "agentPane.display.trajectory.hide": ["commands", "tools"],
    }),
  },
});
