// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The running tray's header: each kind's mark and count, folded and open, and the header's height
// (SubagentTray.tsx, trayHeadKinds.ts `trayHeadParts`, trayHeadHeight.experiment.ts, subagents.css).
// Leo, 2026-11-21, on the redesigned tray over a coordinator's composer that read "pgrep · head · ps"
// folded and "1 message · 1 wait" open: the redesign is "not terrible" but the proportions are off,
// "maybe it's too short rn?", and the open header's counts "almost makes more sense to have at
// baseline", with the kinds' icons, as before, to hover across. Compare the heights (28, 34, 40px)
// with the entry's experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { pinKindsHead } from "../../../gallery/fixtures/kindsHead";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayHeadHeightLook } from "./trayHeadHeight.experiment";

const running = (task: string, minutes: number, action: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const command = (line: string, description: string | undefined, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, ...(description ? { description } : {}), run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const scene = (agents: Subagent[], commands: ReturnType<typeof command>[]) =>
  chat(
    [
      user("Check on the lanes and tell me when the nightly is out", 12),
      ...(agents.length > 0 ? [row(SUBAGENTS, 12, { subagents: agents })] : []),
      activity(commands, 11),
      assistant("I'm waiting on the nightly and asked the tray lane for its status.", 1),
    ],
    { isWorking: true },
  );

/** Leo's coordinator tray: a message to another session and a wait. */
const leoTray = scene(
  [],
  [
    command('acpmux send studio-mac/review "status?"', "Ask the reviewer for its status", 2),
    command("gh pr checks 1234 --watch", "Wait for the PR checks", 1.5),
  ],
);

/** More kinds: a subagent, a message, a wait, a test run and a plain command. */
const mixed = scene(
  [running("Find where the tray header sets its height", 4, "Grep ui-row-height")],
  [
    command('acpmux send studio-mac/review "status?"', "Ask the reviewer for its status", 3),
    command("gh pr checks 1234 --watch", "Wait for the PR checks", 2.5),
    command("cmux-ci test -- bun test src/agent-session", "Run the agent pane tests", 2),
    command("pgrep -f nightly | head -3; ps -o etime= -p 1", undefined, 0.5),
  ],
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

/** The folded header draws each kind's mark and count, the first mark where the lines' icons sit. */
async function folded(ctx: PlayContext): Promise<void> {
  await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kind"));
}

function kinds(ctx: PlayContext): string[] {
  return [...head(ctx)!.querySelectorAll<HTMLElement>(".acpmux-running-tray__kind")].map(
    (kind) => kind.textContent ?? "",
  );
}

/** Hovering a kind names what it counts. */
async function hoverNames(ctx: PlayContext, kind: string, name: string): Promise<void> {
  const selector = `.acpmux-running-tray__kind[data-kind="${kind}"]`;
  await ctx.hover({ selector });
  await ctx.waitFor(() => ctx.document.querySelector(selector)?.getAttribute("title")?.includes(name));
}

export default pinKindsHead(
  agentPaneEntry({
    id: "agent-pane.subagent-tray-head-height",
    title: "Running tray header kinds and height",
    area: "Agent pane",
    height: 360,
    widths: { narrow: 360 },
    anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
    covers: [
      "agent-session/acpmux/subagents/SubagentTray.tsx",
      "agent-session/acpmux/subagents/trayHeadKinds.ts",
      "agent-session/acpmux/subagents/trayHeadHeight.experiment.ts",
    ],
    experiment: {
      definition: trayHeadHeightLook,
      script: [{ name: "the folded header", run: folded }],
    },
    variants: {
      before: {
        note: "Before: the folded header named what runs at 28px, the look Leo found too short; the open header's counts showed only once opened.",
        experiments: { "subagent-tray-fold-head": "one", "subagent-tray-head-height": "row" },
        play: async (ctx) => {
          await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__title"));
          if (head(ctx)!.querySelector(".acpmux-running-tray__kind")) throw new Error("the before look drew kinds");
        },
        snapshot: leoTray,
      },
      "leo-tray": {
        note: "Leo's coordinator tray, folded: \"1 message · 1 wait\", each count after its kind's mark (the message's chat bubble, the wait's clock), then the time and the chevron. Hovering the wait names it.",
        play: async (ctx) => {
          await folded(ctx);
          const read = kinds(ctx).join(" · ");
          if (read !== "1 message · 1 wait") throw new Error(`unexpected header: ${read}`);
          await hoverNames(ctx, "waits", "Wait for the PR checks");
        },
        snapshot: leoTray,
      },
      mixed: {
        note: "A subagent (its harness mark in its tone), a message, a wait, a test run and a plain command, folded: one row of marks and counts.",
        play: async (ctx) => {
          await folded(ctx);
          if (kinds(ctx).length !== 5) throw new Error(`expected five kinds, read ${kinds(ctx).join(" · ")}`);
        },
        snapshot: mixed,
      },
      open: {
        note: "Open, the header keeps the same marks and counts, so folding never changes what it says.",
        play: async (ctx) => {
          await folded(ctx);
          await ctx.click({ selector: ".acpmux-running-tray__head" });
          await ctx.waitFor(() => head(ctx)?.getAttribute("aria-expanded") === "true");
          if (kinds(ctx).length !== 5) throw new Error(`expected five kinds open, read ${kinds(ctx).join(" · ")}`);
        },
        snapshot: mixed,
      },
    },
  }),
);
