// l10n-allow-file: gallery fixtures (commands), not shipped UI.
// The composer hat with background commands, opened, for the feel check that drags its top rim
// (test/feel-tray.test.ts). Leo, 2026-11-22: "the dragging isn't properly relative accurate to
// the cursor, and it's just jumpy all over the place and doesn't have satisfying snap alongs ...
// errant clicks could make it jump". The variants are the extremes a hand meets: one command,
// five, fifty, and commands with huge text.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";

// These variants check the carded head's columns (icon, time, chevron); the one-line head (trayFoldHead
// `line`, the default since Leo, 2026-11-25) draws none while tucked, so they pin the carded `groups` head.
const CARD_HEAD = { "subagent-tray-fold-head": "groups" } as const;
const HUGE =
  "Walk every surface that draws the hat (the bottom stack, a pinned chat, a split pane, the floating chat and the iPhone mirror) and check each keeps its height through a reload, a theme switch and a font size change";

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const COMMANDS = [
  ["bun test webviews/src/agent-session/acpmux/subagents --timeout 30000", "run the hat tests"],
  ["cmux-ci compile-check --app --ref HEAD", "compile on the fleet"],
  ["bun run gallery:dev", "serve the gallery"],
  ["cargo test -p cmux-motion", "test the springs"],
  ["scripts/web-lint.sh", "lint the web UI"],
] as const;

/// The hat's list holds the background commands, so a drag up has lines to show.
const commands = (count: number, huge: boolean) =>
  Array.from({ length: count }, (_, i) => {
    const [line, description] = COMMANDS[i % COMMANDS.length]!;
    return command(
      huge ? `${line} # ${HUGE}` : count > COMMANDS.length ? `${line} # ${i + 1}` : line,
      description,
      2 - i / count,
    );
  });

const snapshot = (count: number, huge = false) =>
  chat(
    [
      user("Land the tray change: compile, test and update the spec", 3),
      activity(commands(count, huge), 2),
      assistant("The tests and the compile are running.", 0.5),
    ],
    { isWorking: true },
  );

const opened = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray[data-open] .acpmux-running-tray__list"));
};

export default agentPaneEntry({
  id: "agent-pane.feel-tray",
  title: "Composer hat with background commands, opened: the feel check's stage",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/trayResize.ts"],
  variants: {
    one: { experiments: CARD_HEAD, note: "One command.", play: opened, snapshot: snapshot(1) },
    five: { experiments: CARD_HEAD, note: "Five commands.", play: opened, snapshot: snapshot(5) },
    fifty: {
      experiments: CARD_HEAD,
      note: "Fifty commands: the list scrolls in place under the cap.",
      play: opened,
      snapshot: snapshot(50),
    },
    huge: {
      experiments: CARD_HEAD,
      note: "Five commands of huge text: each cut at the row's edge.",
      play: opened,
      snapshot: snapshot(5, true),
    },
  },
});
