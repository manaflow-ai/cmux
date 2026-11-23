// l10n-allow-file: gallery fixtures (sample prompts, commands and outputs), not shipped UI.
// The tool rows' type as a transcript look sets it (transcriptLook.ts toolTypeVariables; Leo,
// 2026-11-18: "you guys need to be tuning font sizes for tool calls and such too"): one opened run of
// calls, a command's output shown, in each named look and in four token variants on the cmux look.
// Measured against the references (cmux-design-references index.json): the Claude, Codex and Studio
// apps draw a tool row's words at the reply's size, regular weight, in the text face, and the
// command after the verb in that face too; only the output is code, and Codex's is about 0.92 of its
// text (cmux's 12 at 14 is 0.857). The cmux look sets no token, so it is today's rows.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { TRANSCRIPT_LOOK_KEY, TRANSCRIPT_LOOKS, TRANSCRIPT_TOKENS_KEY } from "./transcriptLook";

const times = (at: number) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - 0.05) });
const shell = (command: string, at: number, output: string) =>
  tool(command, "execute", "completed", { command, output, ...times(at) });

const rows = chat([
  user("Why does the fetch helper give up after one retry?", 7),
  activity(
    [
      tool("Read src/net/retry.ts", "read", "completed", { locations: [{ path: "/work/app/src/net/retry.ts" }] }),
      shell(
        "rg -n 'retryDelay' src/net",
        6,
        "src/net/retry.ts:14:export const retryDelay = (n: number) => 250 * 2 ** n;\n",
      ),
      shell(
        "bun test src/net/retry.test.ts",
        5.8,
        "bun test v1.4.4\n\nsrc/net/retry.test.ts:\n✓ retries a 503 [3.12ms]\n✓ honours Retry-After [1.04ms]\n✓ gives up after five attempts [0.88ms]\n\n 12 pass\n 0 fail\n",
      ),
      shell("git log --oneline -3 -- src/net", 5.6, "a1b2c3d net: retry on 503\n9f8e7d6 net: typed errors\n"),
    ],
    6,
  ),
  assistant(
    "`retryDelay` is fine: the cap was one attempt because `policy.attempts` defaulted to 1. It is 5 now, and the retry tests pass.",
    4.5,
  ),
]);

/// Opens the run, then the test command, so its command and output draw.
const openOutput = async (ctx: PlayContext) => {
  const head = { selector: ".cv-tool.is-run" };
  if (ctx.find(head).getAttribute("aria-expanded") !== "true") await ctx.click(head);
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-step > .cv-command").length >= 3);
  const test = { selector: ".cv-step:nth-child(3) > .cv-command" };
  let last = Number.NaN;
  await ctx.waitFor(() => {
    const row = ctx.find(test);
    const { top } = row.getBoundingClientRect();
    const still = top === last;
    last = top;
    return still;
  });
  if (ctx.find(test).getAttribute("aria-expanded") !== "true") await ctx.click(test);
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__body")));
};

const variant = (display: Record<string, unknown>, note: string): AgentPaneVariant => ({
  note,
  snapshot: rows,
  display,
  play: openOutput,
});
const lookVariant = (name: string) => {
  const look = TRANSCRIPT_LOOKS.find((value) => value.name === name)!;
  const type = Object.entries(look.tokens).filter(
    ([key]) => key.startsWith("toolRow.") || key.startsWith("toolOutput."),
  );
  const set = type.length ? type.map(([key, value]) => `${key} ${value}`).join(", ") : "no tool type token";
  return variant({ [TRANSCRIPT_LOOK_KEY]: name }, `${look.title} look: ${set}.`);
};
const tokens = (values: Record<string, unknown>, note: string) => variant({ [TRANSCRIPT_TOKENS_KEY]: values }, note);

export default agentPaneEntry({
  id: "agent-pane.tool-row-type",
  title: "Tool row type",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/transcriptLook.ts#toolTypeVariables"],
  keywords: ["tool", "font", "size", "weight", "mono", "command", "output", "look"],
  variants: {
    cmux: lookVariant("cmux"),
    claude: lookVariant("claude"),
    codex: lookVariant("codex"),
    studio: lookVariant("studio"),
    larger: tokens(
      { "toolRow.textSize": 1, "toolRow.weight": 500, "toolOutput.textSize": 1 },
      "cmux at the tokens' largest: rows at the full text size in medium weight, output at the text size (14 at 14).",
    ),
    compact: tokens(
      { "toolRow.textSize": 0.93, "toolOutput.textSize": 0.8 },
      "cmux with the rows a step under the reply (13 at 14) and smaller output.",
    ),
    "mono-commands": tokens(
      { "toolRow.commandFont": "mono", "toolRow.textSize": 0.93 },
      "cmux with each command and path in the code face, at 13.",
    ),
    "text-output": tokens(
      { "toolRow.weight": 500, "toolOutput.font": "text", "toolOutput.textSize": 0.93 },
      "cmux with medium-weight rows and output in the text face.",
    ),
  },
});
