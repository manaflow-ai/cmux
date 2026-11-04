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

const running = (harness: string, backgroundsWork = harness === "claude", call = suite, turnTokens?: number) =>
  chat([user("Run the full test suite", 2), assistant("Running the suite.", 1.5), activity([call], 1)], {
    harness,
    backgroundsWork,
    isWorking: true,
    ...(turnTokens === undefined ? {} : { turnTokens }),
  });

/// On a narrow pane the hovered line's words give way behind their ellipsis, and its time, tokens and
/// hint each keep their own room: before #35021 the squeezed counts drew over each other and the hint.
const lineFitsNarrow = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-worked .cv-command__bg"));
  await ctx.resize(340);
  await ctx.hover({ selector: ".cv-worked" });
  const line = ctx.find({ selector: ".cv-worked" }) as HTMLElement;
  const hint = line.querySelector<HTMLElement>(".cv-command__bg")!;
  await ctx.waitFor(() => getComputedStyle(hint).position === "static");
  const parts = [...line.children].filter((part) => part.getBoundingClientRect().width > 0);
  for (let i = 1; i < parts.length; i++) {
    const before = parts[i - 1]!.getBoundingClientRect();
    const after = parts[i]!.getBoundingClientRect();
    if (before.right > after.left + 0.5)
      throw new Error(
        `${parts[i - 1]!.className} ends at ${before.right}, over ${parts[i]!.className} at ${after.left}`,
      );
  }
  const words = line.querySelector<HTMLElement>(".cv-shimmer__row");
  const time = line.querySelector<HTMLElement>(".cv-worked__time");
  const next = time && words?.nextElementSibling;
  if (time && next && time.getBoundingClientRect().right > next.getBoundingClientRect().left + 0.5)
    throw new Error(`the turn's time "${time.textContent}" runs over ${next.className}`);
  for (const count of line.querySelectorAll<HTMLElement>(".cv-worked__count"))
    if (count.scrollWidth > count.clientWidth + 0.5)
      throw new Error(`"${count.textContent}" is cut while the line's words still have room`);
  if (line.getBoundingClientRect().right + 0.5 < hint.getBoundingClientRect().right)
    throw new Error("the hint runs past the line's end");
};

export default agentPaneEntry({
  id: "agent-pane.background-hint",
  title: "Ctrl-B background hint",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/BackgroundHint.tsx"],
  variants: {
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
    narrow: {
      note: "#35021: a described Bash running for minutes, with the turn's tokens, hovered on a narrow pane. The words end in an ellipsis; the time, the tokens and the hint each keep their room, never drawn over each other.",
      snapshot: running("claude", true, described, 3_900),
      checks: {
        layoutShiftMax: {
          value: 0.02,
          reason: "On hover the hint takes its room at the line's end (Leo, 2026-10-24) and the words give way to it.",
        },
      },
      play: lineFitsNarrow,
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
