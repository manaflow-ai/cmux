// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands, session titles), not shipped UI.
// The running tray's header split by kind, and its right column (SubagentTray.tsx, trayHeadKinds.ts,
// subagents.css). Leo, 2026-11-03, on a tray whose header read only "4 commands 6m 47s" over four
// running commands and a finished subagent, whose "Done · 29m 21s" ended past the other lines' times
// in the empty Stop column: "let's align the right + the top should be able to split per background
// task/scheduled wait/subagent/subsession? actually im not sure if we want expectations for other
// sessions to be "sub" and idk how we wanna depict "subagents of a different model family"... i feel
// like we should... but anyways the top bit aka what the collapsed area shows i think can show much
// more interesting stuf fthan it does now + all that alignment can be done better with the side
// background tasks thing and the chevrons with the stop symbols and whatnot and the times".
//
// Every line's time ends on one x, Stop squares sit in one column (empty on a line with none) and
// every chevron, the header's too, in another; the header's panel button sits over the Stop column.
// Five lines fit the list without a scrollbar. The header counts each kind, then what ended ("1
// subagent done") and its failures in red, and a Codex subagent under a Claude chat by its mark.
// Compare the header's arms (trayHeadKinds.experiment.ts) with the entry's experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, SESSION_ID, session, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayHeadKindsLook } from "./trayHeadKinds.experiment";

function agent(task: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  return {
    id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state,
    background: true,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(Math.max(0, minutes - 29.35)) }),
    ...fields,
  };
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

/** Leo's tray: four background commands running and a subagent that finished. */
const leoTray = chat(
  [
    user("Get the nightly guard green and keep the checks running", 40),
    row(SUBAGENTS, 40, { subagents: [agent("Fix nightly guard base red from 93d162ae", 40, "completed")] }),
    activity(
      [
        command("gh run watch 41723867191 --exit-status", "Wait for the nightly run", 6.8),
        command("python3 scripts/check-test-determinism.py --runs 20", "Check test determinism", 5.8),
        command("swift build -c release --product App", "Compile the head", 2.6),
        command("gh pr checks 34260 --watch", "Read the compile-check result", 2),
      ],
      7,
    ),
  ],
  { isWorking: true },
);

/** Every kind at once: a Claude subagent and a Codex one running, a session the agent started, two
 *  commands, and what ended: a subagent done and one that failed. */
const mixed: AcpmuxSnapshot = (() => {
  const base = chat(
    [
      user("Review the tray from both sides, port the history page and keep the tests going", 12),
      row(SUBAGENTS, 12, {
        subagents: [
          agent("Review the tray columns", 9, "running", { action: "Read subagents.css" }),
          agent("Review the header counts", 8, "running", { harness: "codex", action: "Read trayHeadKinds.ts" }),
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
  return {
    ...base,
    sessions: [
      ...base.sessions,
      session({
        sessionId: "child-history",
        title: "Port the history page to React Aria",
        spawnedBy: SESSION_ID,
        startedBy: SESSION_ID,
        indicator: "working",
        status: "running",
        lane: "working",
        createdAt: minutesAgo(6),
      }),
    ],
  };
})();

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

/** Opens the tray and waits for its lines: `lines` of them, or any when the variant is not known. */
async function open(ctx: PlayContext, lines?: number): Promise<void> {
  await ctx.waitFor(() => head(ctx));
  if (head(ctx)!.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => {
    const count = ctx.document.querySelectorAll(".acpmux-running-tray__list .acpmux-agent-line").length;
    return lines === undefined ? count > 0 : count === lines;
  });
}

const box = (node: Element | null | undefined) => node?.getBoundingClientRect();
const centre = (rect: DOMRect) => (rect.left + rect.right) / 2;

/** The right column, as Leo asked: one time edge, one Stop column, one chevron column, the header's
 *  panel button and chevron on them, and no scrollbar under five lines. */
function columns(ctx: PlayContext): void {
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  const lines = [...tray.querySelectorAll<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line")];
  const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
  // Under 400px (the tray's container query) each line takes two rows, so five of them scroll.
  if (lines.length <= 5 && tray.getBoundingClientRect().width > 400 && list.scrollHeight > list.clientHeight + 0.5)
    throw new Error(`five lines overflow the list by ${list.scrollHeight - list.clientHeight}px`);
  const near = (a: number, b: number, what: string) => {
    if (Math.abs(a - b) > 0.5) throw new Error(`${what}: ${a} vs ${b}`);
  };
  const times = lines.map((line) => box(line.querySelector(".acpmux-agent-line__time"))!);
  const tracks = lines.map((line) => box(line.querySelector(".acpmux-agent-line__stop-track"))!);
  const chevrons = lines.map((line) => box(line.querySelector(".acpmux-agent-line__chevron svg"))!);
  for (const [index, time] of times.entries()) {
    near(time.right, times[0]!.right, `line ${index}'s time ends on the column`);
    // The time never runs into Stop's track, empty or not.
    if (time.right > tracks[index]!.left + 0.5) throw new Error(`line ${index}'s time runs into the Stop column`);
    near(centre(tracks[index]!), centre(tracks[0]!), `line ${index}'s Stop column`);
    near(centre(chevrons[index]!), centre(chevrons[0]!), `line ${index}'s chevron`);
  }
  const stops = lines.flatMap((line) => {
    const button = line.querySelector(".acpmux-agent-line__stop-slot > button");
    return button ? [box(button)!] : [];
  });
  for (const stop of stops) near(centre(stop), centre(tracks[0]!), "a Stop square sits in the Stop column");
  near(
    centre(box(head(ctx)!.querySelector(".acpmux-running-tray__status svg"))!),
    centre(chevrons[0]!),
    "header chevron",
  );
  const panel = box(tray.querySelector(".acpmux-running-tray__open"));
  if (panel) near(centre(panel), centre(tracks[0]!), "the header's panel button sits over the Stop column");
}

function title(ctx: PlayContext): string {
  return ctx.find({ selector: ".acpmux-running-tray__title" }).textContent ?? "";
}

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-kinds",
  title: "Running tray header kinds and right column",
  area: "Agent pane",
  height: 440,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/AgentLine.tsx"],
  experiment: {
    definition: trayHeadKindsLook,
    script: [{ name: "open the tray", run: (ctx) => open(ctx) }],
  },
  variants: {
    "leo-tray": {
      note: 'Leo\'s tray (2026-11-03): four background commands and a finished subagent, open. Every time ends on one x (the done line\'s "Done · 29m 21s" no longer runs into the empty Stop column), the Stop squares and the chevrons each sit in one column with the header\'s, and the header says "1 build · 2 waits · 1 command · 1 subagent done", its commands counted by what they do.',
      play: async (ctx) => {
        await open(ctx, 5);
        columns(ctx);
        if (title(ctx) !== "1 build · 2 waits · 1 command · 1 subagent done")
          throw new Error(`unexpected header: ${title(ctx)}`);
      },
      snapshot: leoTray,
    },
    mixed: {
      note: "Every kind: two subagents running (one Codex, by its mark: in the header's stacked marks, or after the counts when the stack has no room for it), a session the agent started, a test run and a server, a subagent done and one failed, in red. The columns hold on every line.",
      play: async (ctx) => {
        await open(ctx, 7);
        columns(ctx);
        if (title(ctx) !== "2 subagents running · 1 session · 1 test run · 1 server · 1 subagent done")
          throw new Error(`unexpected header: ${title(ctx)}`);
        if (ctx.find({ selector: ".acpmux-running-tray__failed" }).textContent?.trim() !== "· 1 failed")
          throw new Error("the failure count reads after the counts");
        // The Codex mark is one of the header's stacked marks, or after the counts.
        if (!ctx.document.querySelector('.acpmux-running-tray__head svg[data-agent="openai"]'))
          throw new Error("the Codex subagent's mark");
      },
      snapshot: mixed,
    },
    folded: {
      note: "Folded, the header still names the newest work (trayFoldHead.experiment.ts), and its chevron stays in the lines' column.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx));
      },
      snapshot: mixed,
    },
  },
});
