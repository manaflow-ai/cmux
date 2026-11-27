// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's `line` header, the default (trayFoldHead.experiment.ts, trayHeadKinds.ts
// `trayHeadLine`). Leo, 2026-11-25: "and did we not finish the composer hat improvements? there's tons
// of unnecessary space to the point where it's just... not great" / "like claude code just has this and
// they tuck it at the very bottom of the transcript after the latest message. i said i wanted composer
// hat bc i wanted that available, and to be able to tuck it away, to see what processes there are?"
//
// One muted sentence, "14 subagents working, 6 background commands running", on the hat's own card at
// the composer's row height, in the chat's text size (Leo, 2026-11-27: "we like the semantic x subagents
// working but we'd like to just remove the hide eye icon and then add the opaque backing to it again
// with proper size"). A click opens the list (name, state, time, Stop); a click again or Esc tucks it.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, user, tool } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";

function agent(task: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  return {
    id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state,
    background: true,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, Math.min(minutes, 4))),
    ...fields,
  };
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

/** Three subagents (one Codex), a dev server and a test watch; one subagent done, one failed. */
const mixed = chat(
  [
    user("Review the tray from both sides and keep the tests going", 12),
    row(SUBAGENTS, 12, {
      subagents: [
        agent("Review the tray columns", 9, "running"),
        agent("Review the header counts", 8, "running"),
        agent("Cross-check the counts", 7, "running", { harness: "codex" }),
        agent("Find the screenshot", 11, "completed"),
        agent("Bisect the flaky fold test", 10, "failed"),
      ],
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 7),
        command("cd ~/Projects/app/webviews && bun test --watch", "Watch the tests", 3),
      ],
      7,
    ),
  ],
  { isWorking: true },
);

/** One background wait, alone: it reads its name. */
const loneCommand = chat(
  [
    user("Watch the nightly", 3),
    activity([command("gh run watch 41723867191 --exit-status", "Wait for the nightly run", 2.5)], 3),
  ],
  { isWorking: true },
);

/** One subagent, alone. */
const loneAgent = chat(
  [
    user("Fix the staging VM", 4),
    row(SUBAGENTS, 4, { subagents: [agent("Fix staging chat VM never getting a machine", 3, "running")] }),
  ],
  { isWorking: true },
);

/** Fourteen subagents over three harnesses and six commands of four kinds: still two groups. */
const burst = chat(
  [
    user("Fan out over every package", 20),
    row(SUBAGENTS, 20, {
      subagents: Array.from({ length: 14 }, (_, index) =>
        agent(`Audit package ${index + 1}`, 19 - index * 0.5, "running", {
          harness: ["claude", "codex", "gemini"][index % 3]!,
        }),
      ),
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 15),
        command("bun test --watch", "Watch the tests", 14),
        command("swift build -c release --product App", "Compile the head", 6),
        command("gh pr checks 34260 --watch", "Wait for the checks", 5),
        command("gh run watch 41723867191", "Wait for the nightly", 4),
        command("python3 scripts/check-test-determinism.py --runs 20", "Check test determinism", 3),
      ],
      15,
    ),
  ],
  { isWorking: true },
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

/** The line's promises: one row of plain words on the hat's card, at the prompt's text size, no eye. */
async function lineHolds(ctx: PlayContext, words: RegExp): Promise<void> {
  await ctx.waitFor(() => words.test(head(ctx)?.textContent ?? "") || undefined);
  const header = head(ctx)!;
  if (header.querySelector("svg, img")) throw new Error("the line draws a mark");
  const tray = header.closest<HTMLElement>(".acpmux-running-tray")!;
  if (!tray.hasAttribute("data-card")) throw new Error("the line has no card under it");
  if (tray.querySelector(".acpmux-hat-hide")) throw new Error("the line draws a hide eye");
  const box = header.getBoundingClientRect();
  if (box.height > 32) throw new Error(`the line is ${box.height}px tall, one row wanted`);
  const view = ctx.document.defaultView!;
  const title = header.querySelector<HTMLElement>(".acpmux-running-tray__title");
  const prompt = ctx.document.querySelector<HTMLElement>(".acpmux-composer-prompt");
  if (title && prompt) {
    const words = view.getComputedStyle(title).fontSize;
    const typed = view.getComputedStyle(prompt).fontSize;
    if (words !== typed) throw new Error(`the line's words are ${words}, the prompt's ${typed}`);
  }
}

const open = async (ctx: PlayContext) => {
  await lineHolds(ctx, /working|running/);
  head(ctx)!.click();
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list > li") ?? undefined);
};

export default agentPaneEntry({
  id: "agent-pane.composer-hat-line",
  title: "Composer hat: one line, as Claude Code's",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 280, normal: 400, wide: 900 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: {
    definition: trayFoldHeadLook,
    script: [{ name: "show the line", run: (ctx) => lineHolds(ctx, /./) }],
  },
  keywords: ["composer hat", "running tray", "background tasks", "subagents", "claude code"],
  variants: {
    burst: {
      note: "The default: 14 subagents working, 6 background commands running, on the hat's card at the composer's row height, in the chat's text size. No eye.",
      play: (ctx) => lineHolds(ctx, /14 subagents working, 6 background commands running/),
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "line", "composer-hat-line-deck": "words" },
    },
    "burst-before": {
      note: "Before: the `groups` header on the same work, a tall bar.",
      play: (ctx) => ctx.waitFor(() => head(ctx)),
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    mixed: {
      note: "3 subagents working, 2 background commands running, 1 failed: the done one needs nothing.",
      play: (ctx) => lineHolds(ctx, /3 subagents working, 2 background commands running, 1 failed/),
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "line", "composer-hat-line-deck": "words" },
    },
    "lone-command": {
      note: "One background command: the line reads it in the singular, never a bare 1.",
      play: (ctx) => lineHolds(ctx, /^1 background command running$/),
      snapshot: loneCommand,
      experiments: { "subagent-tray-fold-head": "line", "composer-hat-line-deck": "words" },
    },
    "lone-subagent": {
      note: "One subagent: 1 subagent working.",
      play: (ctx) => lineHolds(ctx, /^1 subagent working$/),
      snapshot: loneAgent,
      experiments: { "subagent-tray-fold-head": "line", "composer-hat-line-deck": "words" },
    },
    "mixed-open": {
      note: "Clicked open: the list of what runs, each with its name, state, time and Stop; a click again or Esc tucks it.",
      play: open,
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "line", "composer-hat-line-deck": "words" },
    },
  },
});
