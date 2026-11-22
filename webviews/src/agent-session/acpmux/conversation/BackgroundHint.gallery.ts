// l10n-allow-file: gallery fixtures (sample prompts and commands), not shipped UI.
// A Claude Code chat's running command (BackgroundHint.tsx): its row ends with "⌃B to run in
// background", and Ctrl-B moves the command to the background (runInBackground.ts). The model
// router's `cmux` chat is Claude Code too. A Codex chat's running command, or an ACP agent's that a
// user named `claude-acp`, has no hint: acpmux's summary says which (`backgroundsWork`). The hint is
// a button that does what Ctrl-B does, and a command already in the background has none.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { backgroundHintRoom } from "./backgroundHintRoom.experiment";

const suite = tool("cargo test --workspace", "execute", "in_progress", {
  command: "cargo test --workspace",
  inputSummary: JSON.stringify({ command: "cargo test --workspace" }),
  startedAt: minutesAgo(1),
});

/// A Bash Claude Code gave a description, as in Leo's screenshot (2026-11-03): the line reads it.
const described = tool("Check for Ultra runners on GitHub and ultra1", "execute", "in_progress", {
  command: "gh api /orgs/manaflow-ai/actions/runners --jq '.runners[].name' | grep -i ultra",
  description: "Check for Ultra runners on GitHub and ultra1",
  inputSummary: JSON.stringify({ command: "gh api /orgs/manaflow-ai/actions/runners" }),
  startedAt: minutesAgo(16),
});

/// The same command once Ctrl-B moved it: it still runs, in the background.
const moved = { ...suite, tool: { ...suite.tool!, background: { state: "running" as const } } };

/// A long command, as in Leo's screenshot (2026-11-06): its words reach the line's end, before the
/// step's own time, the turn's time and its tokens.
const long = tool("python3 -c 'import json,sys,re d=json.load(sys.stdin)'", "execute", "in_progress", {
  command:
    'gh pr view 37031 --json comments | python3 -c \'import json,sys,re d=json.load(sys.stdin); print([c for c in d["comments"] if re.search("SHIP", c["body"])])\'',
  inputSummary: JSON.stringify({ command: "python3 -c 'import json,sys,re'" }),
  startedAt: minutesAgo(0.15),
});

const running = (harness: string, backgroundsWork = harness === "claude", call = suite, tokens?: number) =>
  chat([user("Run the full test suite", 2), assistant("Running the suite.", 1.5), activity([call], 1)], {
    harness,
    backgroundsWork,
    isWorking: true,
    ...(tokens ? { turnTokens: tokens } : {}),
  });

const LINE = ".cv-worked.is-below";
/// The line's times and tokens, where each draws.
const counts = (ctx: PlayContext) =>
  [
    ...ctx.document.querySelectorAll<HTMLElement>(
      `${LINE} .cv-worked__time, ${LINE} .cv-worked__own, ${LINE} .cv-worked__count`,
    ),
  ].map((node) => node.getBoundingClientRect());

/// Leo, 2026-11-06, hovering the line's right edge: "this flickers". Pointing at the line fades the
/// hint in and moves nothing: every time and count keeps its box, and no two overlap.
const hoverHoldsCounts = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(`${LINE} .cv-command__bg`));
  const before = counts(ctx);
  await ctx.hover({ selector: LINE });
  await ctx.waitFor(
    () => getComputedStyle(ctx.document.querySelector<HTMLElement>(`${LINE} .cv-command__bg`)!).opacity === "1",
  );
  const after = counts(ctx);
  if (after.length !== before.length || after.some((box, index) => Math.abs(box.left - before[index]!.left) > 0.5))
    throw new Error("pointing at the live line moved its times or tokens");
  for (let index = 1; index < after.length; index++)
    if (after[index]!.left < after[index - 1]!.right - 0.5)
      throw new Error("the live line's times or tokens overlap under the pointer");
};

export default agentPaneEntry({
  id: "agent-pane.background-hint",
  title: "Ctrl-B background hint",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/BackgroundHint.tsx"],
  // Where the hint keeps its room (variant long-hovered): the line's end (shipped), right after the
  // tokens, or shown there at rest.
  experiment: {
    definition: backgroundHintRoom,
    script: [{ name: "Hover the live line", run: hoverHoldsCounts }],
  },
  variants: {
    "long-hovered": {
      // Reads the clock on the live line (liveTurnClock.experiment.ts `line`); the shipped `top` puts it over the work.
      experiments: { "live-turn-clock": "line" },
      note: 'Leo, 2026-11-06, on "8s · 2m5 1.4K toke" drawn over itself while he hovered the line\'s right edge: "this flickers". A long command with its time, the turn\'s and its tokens; hovered, the hint fades in its kept room and every count holds still.',
      snapshot: running("claude", true, long, 1_400),
      play: hoverHoldsCounts,
    },
    claude: {
      note: "A Claude Code chat's running command: the row ends with the Ctrl-B hint.",
      snapshot: running("claude"),
    },
    router: {
      note: "The model router's chat (Claude Code named `cmux`): the row ends with the Ctrl-B hint.",
      snapshot: running("cmux", true),
    },
    codex: {
      note: "A Codex chat's running command: no hint, Ctrl-B stays the composer's.",
      snapshot: running("codex"),
    },
    described: {
      note: 'Leo, 2026-11-03: "this run in background sometimes i can\'t actually do anything to put it in the background". A described Bash running 16 minutes: hover the line and the hint is a button that moves it, wherever the keyboard is.',
      snapshot: running("claude", true, described),
    },
    backgrounded: {
      note: "The command already moved to the background: no hint, and Ctrl-B stays the composer's.",
      snapshot: running("claude", true, moved),
    },
    "claude-acp": {
      note: "An ACP agent a user named `claude-acp`: acpmux refuses its Ctrl-B, so no hint.",
      snapshot: running("claude-acp", false),
    },
  },
});
