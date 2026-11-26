// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's `groups` header (trayFoldHead.experiment.ts, trayHeadKinds.ts `trayHeadGroups`,
// HeadSummary.tsx) on the composer's columns. Leo, 2026-11-24 00:18Z: "for one
// at least now the alignment becomes... maybe awkward? against the (currently fixing, ignore the
// outline) attachment + button. lucas raised that. ... the background command type delineation was my
// doing anyways. the simplest view is just... subagents. other background things. boom. waits, etc,
// they're just normal tool calls that are backgrounded instead of dozesns of possible different
// buttons. we can obviously keep the icons the stuff but... we can group them up more if we think it's
// much better looking that way."
//
// Two groups: subagents, then everything else backgrounded. In words while they fit ("3 subagents · 2
// tasks in background"), then shorter ("3 subagents · 2 tasks"), then each group's mark and number;
// a lone item reads its name. Waiting and failed follow only when they need the person. The lines
// under it keep every item's own mark. The header's first mark centres on the composer's +, its words
// start where the prompt's do (cmux#56151: the plan bar's Claude mark sat right of the +, its words
// right of the placeholder). Compare the arms side by side at 280, 400 and 900 px.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, user, tool } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { PLUS_PICKER } from "../composerSelectors";
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

/** One subagent, alone: its mark and its task. */
const loneAgent = chat(
  [
    user("Fix the staging VM", 4),
    row(SUBAGENTS, 4, { subagents: [agent("Fix staging chat VM never getting a machine", 3, "running")] }),
  ],
  { isWorking: true },
);

/** cmux#56151's hat: one Claude subagent done, "1 subagent done". Its first mark centres on the +, its
 *  words start at the prompt's. */
const oneDone = chat(
  [
    user("Fix the composer hat's alignment", 14),
    row(SUBAGENTS, 12, { subagents: [agent("Measure every row over the composer", 8, "completed")] }),
  ],
  { isWorking: true, turnStartedAtMs: minutesAgo(14) },
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
const summary = (ctx: PlayContext) =>
  head(ctx)?.querySelector<HTMLElement>(".acpmux-running-tray__summary[data-summary]");

/** The groups' promises at whatever width the stage has. */
function groupsHold(ctx: PlayContext, kinds: readonly string[]): void {
  const header = head(ctx)!;
  const line = summary(ctx);
  if (!line) throw new Error("no summary header");
  if (/running/i.test(header.textContent ?? "")) throw new Error(`the header says running: ${header.textContent}`);
  const drawn = [
    ...line.querySelectorAll<HTMLElement>(":scope .acpmux-running-tray__summary-line > * > [data-kind]"),
  ].map((kind) => kind.dataset.kind ?? "");
  for (const kind of drawn)
    if (!kinds.includes(kind)) throw new Error(`the header draws ${kind}, only ${kinds.join(", ")} expected`);
  const time = header.querySelector<HTMLElement>(".acpmux-running-tray__time");
  if (time && time.scrollWidth > time.clientWidth + 0.5) throw new Error("the time is clipped");
}

/// The header's first mark centres on the + button, its words start at the prompt's (cmux#56151).
/// `whole`: the header must have both, a mark and words (the plan-and-done hat says nothing else).
function columnHolds(ctx: PlayContext, whole = false): void {
  const mark = head(ctx)?.querySelector<HTMLElement>(
    // A lone finished subagent beside the plan draws its own mark in the stack slot (SubagentTray's
    // `head === "stack" || lone` arm), not the lineage icon.
    "[data-kind] svg, [data-kind] .cv-sender-icon__main, .acpmux-lineage__icon svg, .acpmux-running-tray__stack-mark",
  );
  // A groups header's words are its first kind's; a header with no group (a plan and one finished
  // subagent) is one line of words (SubagentTray's title).
  const words =
    head(ctx)?.querySelector<HTMLElement>(".acpmux-running-tray__kind-text") ??
    head(ctx)?.querySelector<HTMLElement>(".acpmux-running-tray__title");
  const plus = ctx.document.querySelector<HTMLElement>(PLUS_PICKER);
  const prompt = ctx.document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-placeholder");
  if (whole && !(mark && words && plus && prompt))
    throw new Error(
      `the hat draws ${[!mark && "no mark", !words && "no words", !plus && "no +", !prompt && "no prompt"].filter(Boolean).join(", ")}; its header holds ${[...(head(ctx)?.querySelectorAll("[class]") ?? [])].map((node) => node.getAttribute("class")).join(" | ")}`,
    );
  if (!mark || !plus) return;
  const centre = (box: DOMRect) => box.left + box.width / 2;
  const markAt = centre(mark.getBoundingClientRect());
  const plusAt = centre(plus.getBoundingClientRect());
  if (Math.abs(markAt - plusAt) > 0.75) throw new Error(`the hat's mark centres at ${markAt}, the + at ${plusAt}`);
  if (!words || !prompt) return;
  const wordsAt = words.getBoundingClientRect().left;
  const promptAt = prompt.getBoundingClientRect().left;
  if (Math.abs(wordsAt - promptAt) > 0.75)
    throw new Error(`the hat's words start at ${wordsAt}, the prompt at ${promptAt}`);
}

const show = async (ctx: PlayContext) => {
  await ctx.waitFor(() => summary(ctx));
};

/// The plan-and-done hat: its one finished subagent counts in no group (trayHeadGroups draws only
/// what runs, waits or failed), so no groups summary draws; the header is the plan's words. Wait for
/// the plan's count, and say what the header drew when it never comes.
const showPlan = async (ctx: PlayContext) => {
  try {
    await ctx.waitFor(() => /\b4\b.*\b6\b/.test(head(ctx)?.textContent ?? ""));
  } catch (error) {
    throw new Error(`the hat never showed the plan's 4 of 6: ${JSON.stringify(head(ctx)?.textContent ?? null)}`, {
      cause: error,
    });
  }
};

export default agentPaneEntry({
  id: "agent-pane.composer-hat-groups",
  title: "Composer hat groups: subagents and background",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 280, normal: 400, wide: 900 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/HeadSummary.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: { definition: trayFoldHeadLook, script: [{ name: "show the header", run: (ctx) => show(ctx) }] },
  keywords: ["composer hat", "running tray", "background tasks", "subagents", "alignment"],
  variants: {
    mixed: {
      note: "The default: 3 subagents · 2 tasks in background, then the failed one's 1 in red; the done one needs nothing. Narrow, 3 subagents · 2 tasks, then the two marks and numbers. The hat's mark centres on the +, its words at the prompt's.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background", "failed"]);
        columnHolds(ctx);
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    "one-done": {
      note: "cmux#56151: 1 subagent done. Its mark centres on the +, its words start at the prompt's, the panel button and the chevron sit over Stop and the mic.",
      play: async (ctx) => {
        await showPlan(ctx);
        columnHolds(ctx, true);
      },
      snapshot: oneDone,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    "mixed-marks": {
      note: "The `group-marks` arm: the two groups as marks and numbers at every width; hover a group for its names.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background", "failed"]);
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "group-marks" },
    },
    "mixed-kinds-before": {
      note: "Before: the `summary` arm, a kind per command (subagents, servers, tests ...).",
      play: show,
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "summary" },
    },
    "lone-command": {
      note: "One background wait: its name, never a bare 1.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["background"]);
      },
      snapshot: loneCommand,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    "lone-subagent": {
      note: "One subagent: its mark and its task.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents"]);
      },
      snapshot: loneAgent,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    burst: {
      note: "Fourteen subagents over three harnesses and six commands of four kinds: still 14 subagents · 6 tasks in background, never a dozen kinds.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background"]);
      },
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "groups" },
    },
    "burst-kinds-before": {
      note: "Before, on the same work: a kind per harness and per command kind.",
      play: show,
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "summary" },
    },
  },
});
