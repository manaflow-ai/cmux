// l10n-allow-file: gallery fixtures (prompts, subagent names, commands, chat titles), not shipped UI.
// Running subagents, background commands and chats the agent started in one tray at the foot of
// the chat, right above the composer (SubagentTray.tsx, runningTray.ts), never in the middle of
// history, in a turn and after it ("Running in background · …"): one running is its line alone;
// several get a header ("3 subagents running · 1 command") with a line each; past three they start
// folded to the header. The transcript has no "Running in background" row. A subagent that ended
// remains a bounded status card in the tray and leaves one line where it ended
// (SubagentDoneLine.tsx), a failure in the danger color, a stopped one with why when known, and
// Restart on hover for one that did not finish. The tray's lines are the summary card's
// Subagents rows (AgentLine.tsx). The group card and the agents pill this replaces are
// subagents.gallery.ts, under Debug Settings agentPane.debug.subagentTray off.
import { agentPaneEntry } from "../../../gallery/format";
import {
  activity,
  assistant,
  chat,
  row,
  session,
  SESSION_ID,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, SubagentFold, type Subagent } from "./subagentFold";
import { trayPanelLook } from "./trayPanel.experiment";

const prompt = "Find out how the daemon updates itself, and check the docs agree";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.3, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

const durationAgent = (name: string, durationMs: number, fields: Partial<Subagent> = {}): Subagent =>
  agent(name, 0, "running", { startedAt: GALLERY_NOW - durationMs, ...fields });

/** A Bash call Claude runs in the background, still running. */
const devServer = activity(
  [
    tool("bun run dev", "execute", "completed", {
      inputSummary: JSON.stringify({ command: "bun run dev", run_in_background: true }),
      startedAt: minutesAgo(1.5),
    }),
  ],
  1.5,
);

// The raw assignment from Leo's 2026-11-04 running-strip screenshot. Synthetic paths and data;
// the executed SHA lookup stays named, while flags and interpolation live in the tooltip/output.
const glyphCheck =
  "SHA=$(git rev-parse HEAD); cmux-ci run --class light --key glyph-parity-${SHA:0:12} --ref $SHA --script scripts/check-glyphs.sh";
const glyphCheckScene = (description?: string) =>
  chat(
    [
      user("Check the glyphs on the fleet", 9),
      activity(
        [
          tool(glyphCheck, "execute", "completed", {
            inputSummary: JSON.stringify({
              command: glyphCheck,
              ...(description ? { description } : {}),
              run_in_background: true,
            }),
            startedAt: minutesAgo(8.75),
          }),
        ],
        8.75,
      ),
    ],
    { isWorking: true },
  );

/** A long shell line Claude runs in the background, still running (Leo 2026-10-21: "is that a
 * command or a subagent?"). */
const testRun = activity(
  [
    tool("cd ~/fun/cmux-wt/chromium-transparency && RED=cb8f4178; GREEN=1 bun test", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/fun/cmux-wt/chromium-transparency && RED=cb8f4178; GREEN=1 bun test",
        description: "Run red/green tests",
        run_in_background: true,
      }),
      startedAt: minutesAgo(58.5),
    }),
  ],
  58.5,
);

/** A Bash call in the background that says what it does, behind a `cd` prefix. */
const described = activity(
  [
    tool("cd ~/Projects/cmux && cmux-ci compile-check --app", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/Projects/cmux && cmux-ci compile-check --app",
        description: "Compile the app on the fleet",
        run_in_background: true,
      }),
      startedAt: minutesAgo(1.4),
    }),
    tool("cd ~/Projects/cmux/webviews && CI=1 bun test test/subagent-tray.test.tsx", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/Projects/cmux/webviews && CI=1 bun test test/subagent-tray.test.tsx",
        run_in_background: true,
      }),
      startedAt: minutesAgo(1.3),
    }),
  ],
  1.4,
);

/** A running turn with a five-step todo list and three background commands (the tray's hat). */
function planChat() {
  return chat(
    [
      user("Land the tray change: compile, test and update the spec", 3),
      row("plan", 2.9, {
        plan: [
          { content: "Read the tray and its tests", status: "completed" },
          { content: "Move the plan into the hat", status: "completed" },
          { content: "Run the tray tests", status: "in_progress" },
          { content: "Compile the app on the fleet", status: "pending" },
          { content: "Update the design spec", status: "pending" },
        ],
      }),
      devServer,
      described,
      assistant("The plan is in the hat now. The tests and the compile are running.", 0.5),
    ],
    { isWorking: true },
  );
}

/** Background shell lines anyone runs, with no description, so each reads by a built-in rule
 * (session-info/commandRules.ts; Leo, 2026-11-03: "we should be able to parse these more... like
 * instead of raw things, we should be able to deterministically/heuristically have stuff"). */
const RAW_COMMANDS = [
  'python3 -c "import time; time.sleep(560)"; GH_QUOTA_TIMEOUT=1 gh pr view 34769',
  "gh pr merge 34769 -R manaflow-ai/cmux --squash --match-head-commit 0123abcd",
  "cd ~/Projects/cmux && git push -q origin HEAD:lane/hat-command-labels 2>&1 | tail -3",
  "cd webviews && bun test test/command-rules.test.ts 2>&1 | tail -20",
  "ssh build-host 'cd ~/app && cargo test -p acpmux'",
  "docker compose up -d 2>&1 | tail -5",
];
/** Leo's own fleet tools from his screenshot, which read in words only with the `cmux-fleet` preset
 * on (session-info/commandRulePresets.ts: Leo asked that our own tools not be built in), and a rule
 * of one's own. */
const FLEET_COMMANDS = [
  // The preset's CI-wait rule is covered by test/command-rules.test.ts; a gallery fixture names no fleet tool
  // (scripts/cmux-next/check-fixture-host-names.py), so the scene starts a session instead.
  "sessions new -n 'Tray command labels' --brief brief.md",
  'cmux-ci test --setup playwright --timeout 2400 --workflow-ref feat-cmux-next -- "$(cat check.sh)"',
  "cmux-ci run --key sr2c-ctx-34769-$(date +%s) --class light --script check.sh --ref HEAD",
  "deploy staging --wait",
];
const fleetCommands = activity(
  FLEET_COMMANDS.map((command, index) =>
    tool(command, "execute", "completed", {
      inputSummary: JSON.stringify({ command, run_in_background: true }),
      startedAt: minutesAgo(4 - index),
    }),
  ),
  4,
);
const rawCommands = activity(
  RAW_COMMANDS.map((command, index) =>
    tool(command, "execute", "completed", {
      inputSummary: JSON.stringify({ command, run_in_background: true }),
      startedAt: minutesAgo(6 - index),
    }),
  ),
  6,
);

/** A chat this chat's agent started with its `start_session` tool, its turn running or ended. */
const child = (id: string, title: string, minutes: number, running: boolean, doing?: string, doingTool?: string) =>
  session({
    sessionId: id,
    title,
    spawnedBy: SESSION_ID,
    startedBy: SESSION_ID,
    indicator: running ? "working" : "done",
    status: running ? "running" : "idle",
    createdAt: minutesAgo(minutes),
    ...(running && { lane: "working" as const }),
    ...(doing && { doing }),
    ...(doingTool && { doingTool }),
  });

/** The subagents a Codex chat's records fold into, as acpmux wrote them for Leo's chat (2026-10-22):
 *  the child needs_you_review reported the chat's own thread as running under its own session, and
 *  every later record of the chat came tagged with the chat's id. The fold reads them by lineage. */
function codexLineage(): Subagent[] {
  const chatId = "01a1658b-c32f-72b1-ab04-d5444235a91c";
  const review = "01a16655-c696-7982-9c38-9ededd986f9b";
  const priorArt = "01a16656-bb2d-7513-b459-4a893451d37a";
  const fold = new SubagentFold();
  // The chat's own thread, as its summary names it.
  fold.chat = chatId;
  let seq = 0;
  const feed = (minutes: number, sessionId: string, update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    const msg = { method: "session/update", params: { sessionId, update, _meta: { acpmux } } };
    fold.reduce({ seq, at: minutesAgo(minutes), msg }, update);
  };
  const say = { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Starting the reviews." } };
  feed(22.5, chatId, say, {});
  feed(
    22.2,
    chatId,
    { sessionUpdate: "subagent_spawned", subagentSessionId: review },
    {
      subagents: [{ id: review, parent: null, name: "needs_you_review", task: "needs_you_review", state: "running" }],
    },
  );
  feed(
    21.97,
    review,
    { sessionUpdate: "subagent_state_update", subagentSessionId: chatId, state: "running" },
    {
      subagent: review,
      subagents: [{ id: chatId, parent: review, state: "running" }],
    },
  );
  feed(
    21.2,
    chatId,
    { sessionUpdate: "subagent_spawned", subagentSessionId: priorArt },
    {
      subagent: chatId,
      subagents: [{ id: priorArt, parent: chatId, name: "needs_you_prior_art", task: "needs_you_prior_art" }],
    },
  );
  return fold.all().map((agent) => ({ ...agent, action: agent.parent === null ? "git show --stat" : "Edit 2 files" }));
}

/** Leo's panel (2026-10-25, synthetic names): two chats running whose doing lines are raw shell
 *  lines, and `done` subagents that ended, one a minute apart; `done` 3 makes the two-agent panel,
 *  116 the 118-agent one, every line in the list that scrolls. */
const INFRA_DOING = "cd /Users/you/Projects/checkouts/workspace/broker-host-gh && sed -i '' 's/old/new/' broker.ts";

function panel(done: number, running = 2, lead: AcpmuxRow[] = []) {
  const ended = Array.from({ length: done }, (_, index) =>
    agent(`Lane ${String(index + 1).padStart(3, "0")}`, 130 - index, "completed", {
      kind: "general-purpose",
      ran: 1,
      id: `agent-lane-${index + 1}`,
    }),
  );
  const base = chat(
    [
      ...lead,
      user("Fan out: one lane per area, and keep me posted", 140),
      group(ended, 130),
      assistant("The lanes are running; the two chats below are still going.", 2),
    ],
    { isWorking: true },
  );
  return {
    ...base,
    sessions: [
      ...base.sessions,
      child("child-infra", "claude-sr2/fanout-infra", 6, true, INFRA_DOING, INFRA_DOING),
      child(
        "child-card",
        "claude-sr2/subsession-card",
        5,
        running > 1,
        "Check the card's doing line · Read AgentCard.tsx",
        "Read AgentCard.tsx",
      ),
    ],
  };
}

/** The tray's head is in view and inside the tray's box, and the point at its middle is the head. */
function headInView(ctx: PlayContext): void {
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (!head) throw new Error("the tray's header must stay mounted");
  const box = tray.getBoundingClientRect();
  const rect = head.getBoundingClientRect();
  if (rect.height < 20 || rect.top < box.top - 0.5 || rect.bottom > box.bottom + 0.5)
    throw new Error(`the header must sit inside the tray (${rect.top}-${rect.bottom} in ${box.top}-${box.bottom})`);
  const hit = ctx.document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
  if (!hit || !head.contains(hit)) throw new Error("the header must be the thing drawn at its place");
}

/** Opens the tray, scrolls the list to its end, then checks the head stays. Every ended line is in
 *  the list: there is no View all (Leo, 2026-11-01: "just let it be scroll-downable"). */
const scrollPanel = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  // A variant with one line has no header to keep, and nothing to scroll.
  if (!head) return;
  if (head.getAttribute("aria-expanded") !== "true") {
    await ctx.click({ selector: ".acpmux-running-tray__head" });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list"));
  }
  if (ctx.document.querySelector(".acpmux-running-tray__finished")) throw new Error("the tray has no View all");
  await ctx.scroll({ selector: ".acpmux-running-tray__list" }, "bottom");
  headInView(ctx);
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  if (tray.scrollTop !== 0) throw new Error("the tray never scrolls as a whole; only its list does");
};

const panelScript = [
  {
    name: "the panel at rest",
    run: async (ctx: PlayContext) => {
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
      if (ctx.document.querySelector(".acpmux-running-tray__head")) headInView(ctx);
    },
  },
  { name: "open all and scroll to the end", run: scrollPanel },
];

/** A headed tray starts folded to its header (cmux#28875): open it, as the person clicks it. */
const openTray = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (!head || head.getAttribute("aria-expanded") === "true") return;
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list"));
};

/** Opens the tray, waits for its live `count` lines, and checks no group card is left in the
 *  transcript. */
const trayLines = (count: number) => async (ctx: PlayContext) => {
  await openTray(ctx);
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(".acpmux-running-tray li:not([data-finished]) .acpmux-agent-line").length === count,
  );
  if (ctx.document.querySelector(".cv-subagents"))
    throw new Error("a running subagent must not draw a transcript card");
  if (ctx.document.querySelector(".acpmux-agents-pill"))
    throw new Error("the tray is the agents chip; no pill beside it");
};

/** A finished turn folds its work, each subagent's line with it (turns.ts `foldSegments`): open the
 * turn's Worked for, then wait for what the state shows. */
const openFold = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-worked"));
  await ctx.click({ selector: ".cv-worked" });
};

/** The conversation before the fan-out, so the transcript runs past the pane and the tray opens over
 *  the latest rows (Leo, 2026-11-01: "there's a layout shift when i expand it"). */
const EARLIER: AcpmuxRow[] = [
  user("The webview checks went red on the base again", 190),
  assistant(
    "Two files fail: the transcript's fold anchor and the composer's queue. Both broke after the last merge into the base; I'll bisect them.",
    185,
  ),
  user("Bisect both, and look at the tray while you're there", 170),
  assistant(
    "The fold anchor goes back to a measurement change; the queue failure is a timing race in its test. I'll fan out a lane for each.",
    160,
  ),
];

/** The latest row's top, in the viewport. */
function latestTop(ctx: PlayContext): number {
  const rows = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-row")];
  return rows.at(-1)?.getBoundingClientRect().top ?? Number.NaN;
}

/** Folds the tray (it opens with a short list), then opens it again, and says how far the latest row moved. */
const expandTray = (placement: "composer" | "after-latest") => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  const head = () => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
  if (head().getAttribute("aria-expanded") === "true") {
    await ctx.click({ selector: ".acpmux-running-tray__head" });
    await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-running-tray__fold"));
  }
  const before = latestTop(ctx);
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list"));
  const moved = latestTop(ctx) - before;
  if (placement === "composer" && Math.abs(moved) > 0.5)
    throw new Error(`opening the tray on the composer moved the transcript ${moved.toFixed(1)}px`);
};

/** A running line's look (Leo, 2026-11-03: "do we really need a running symbol vs just having the
 *  time and a square stop button?"): opens the tray, gives it one trayStopLook arm, and checks each
 *  running line with a time shows no spinner and no Running word, only its time and a filled Stop. */
const runningStop = (arm: "solid" | "muted" | "boxed") => async (ctx: PlayContext) => {
  await trayLines(2)(ctx);
  ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!.dataset.stop = arm;
  const running = [
    ...ctx.document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line[data-timed]"),
  ];
  if (running.length !== 2) throw new Error(`two running lines with a time, not ${running.length}`);
  for (const line of running) {
    if (line.querySelector(".acpmux-lineage__icon .cv-spinner, .acpmux-lineage__icon [data-spinner]"))
      throw new Error("a running line with its time draws no spinner");
    if (line.querySelector(".acpmux-summary-agent__state")) throw new Error("a running line shows no Running word");
    if (!line.querySelector(".acpmux-agent-line__time")?.textContent) throw new Error("a running line shows its time");
    if (!line.querySelector(".acpmux-agent-line__stop-slot > button svg"))
      throw new Error("a running subagent's line keeps its Stop");
  }
};

/** Two subagents still running and one done, for the running line's Stop arms. */
const runningStopChat = chat(
  [
    user("Fan the review out", 40),
    group(
      [
        agent("Make autoland land again", 39, "running", { action: "Read land_ready.py" }),
        agent("Run Codex review via router", 24, "running", { action: "Bash" }),
        agent("Check the docs", 12, "completed", { ran: 0.6 }),
      ],
      39,
    ),
  ],
  { isWorking: true },
);

const harnessIdentityChat = chat(
  [
    user("Keep the harness identities visible while the checks run", 4),
    group(
      [
        agent("Review Claude", 3.2, "running", { harness: "claude", action: "Read the review" }),
        agent("Review Codex", 2.4, "running", { harness: "codex", action: "Check the diff" }),
        agent("Unknown helper", 1.8, "completed", { action: "Summarize the result" }),
      ],
      3.2,
    ),
  ],
  { isWorking: true },
);

export default agentPaneEntry({
  id: "agent-pane.subagent-tray",
  title: "Running subagents tray",
  area: "Agent pane",
  height: 520,
  // The header and the composer stay put while the tray opens or folds.
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/subagents/restart.ts",
  ],
  // The panel's looks (trayPanel.experiment.ts), on the two- and 118-agent panels.
  experiment: { definition: trayPanelLook, script: panelScript },
  variants: {
    geometry: {
      note: "Geometry fixture: running, completed and cancelled rows share the trailing tracks above a running empty composer.",
      play: async (ctx) => {
        await openTray(ctx);
      },
      snapshot: chat(
        [
          user("Keep the three task states visible", 4),
          group(
            [
              agent("Running check", 2.1, "running", { action: "Run the check" }),
              agent("Done check", 3.8, "completed", { ran: 1.2 }),
              agent("Cancelled check", 3.8, "cancelled", { ran: 1.4 }),
            ],
            2.1,
          ),
          assistant("The checks are visible above the composer.", 1),
        ],
        { isWorking: true },
      ),
    },
    "grid-31": {
      note: "Grid fixture: 31 rows (29 ended and two running), expanded with the header visible.",
      snapshot: panel(29),
      play: async (ctx) => {
        await scrollPanel(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 31);
      },
    },
    "panel-two": {
      note: "Leo's panel with two chats running and three ended (2026-10-25: \"this section, the whatever background tasks ... it's kind of wack\"): the header pinned on top, running first, then the latest that ended; no line carries a subtitle, so none shows a raw shell line.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await openTray(ctx);
        headInView(ctx);
        // No line carries a subtitle, so none shows a raw shell line (subagents/AgentLine.tsx).
        const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        if (tray.querySelector(".acpmux-summary-agent__kind"))
          throw new Error("a tray line carries no subtitle: what it does is its tooltip");
        if ((tray.textContent ?? "").includes("cd /Users/")) throw new Error("a line never shows a raw shell line");
      },
      snapshot: panel(3),
    },
    "panel-one-running": {
      note: "One of the two chats ended: the header and its collapse stay while ended lines show (it used to unmount once fewer than two ran).",
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
        headInView(ctx);
      },
      snapshot: panel(3, 1),
    },
    "short-dock": {
      note: "A 300px pane with a constrained dock: the header stays reachable when the list gives up its height; every line is in the list, no View all.",
      height: 400,
      snapshot: chat(
        [
          user("Keep the running check and completed checks accessible", 4),
          group(
            [
              durationAgent("Long check", 12 * 60 * 60_000 + 59 * 60_000 + 59_000),
              ...Array.from({ length: 4 }, (_, index) => agent(`Completed check ${index + 1}`, 3, "completed")),
            ],
            3,
          ),
        ],
        { isWorking: true },
      ),
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray li[data-finished]"));
        const shell = ctx.document.querySelector<HTMLElement>(".acpmux-shell")!;
        shell.style.width = "300px";
        shell.style.maxWidth = "100%";
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray[data-narrow]"));
        const dock = ctx.document.querySelector<HTMLElement>(".acpmux-dock")!;
        const composer = dock.querySelector<HTMLElement>(".acpmux-composer")!;
        const header = dock.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
        // Leave less than the header and the list need. The tray's minimum must win as
        // the dock and composer share their height; the list is the part that may collapse.
        dock.style.maxHeight = `${composer.getBoundingClientRect().height + header.getBoundingClientRect().height}px`;
      },
    },
    "panel-118": {
      note: 'The same panel with 118 agents, every ended one opened and the list scrolled to its end (Leo: the collapse at the top "disappears for some reason ... sometimes"): the header stays pinned on top; only the list scrolls, every line in it (no View all).',
      play: scrollPanel,
      snapshot: panel(116),
    },
    "workflow-progress": {
      note: "A workflow reports completed/started agents, failures and queued agents in the default tray (its token usage is Session Info's).",
      // Workflows are on by default, which shows this as the workflow card instead; a host that
      // turns them off (`workflowLabs` false) still gets the tray line this state covers.
      workflowLabs: false,
      play: trayLines(1),
      snapshot: chat(
        [
          user("Review the changes across all modules", 2),
          group(
            [
              agent("Review modules", 1.8, "running", {
                kind: "workflow",
                action: "Review",
                agents: { done: 1037, started: 10101, failed: 212, queued: 1450 },
                tokens: 1_200_000,
                phases: [{ index: 0, title: "Review" }],
                workflowAgents: new Map([
                  [0, { index: 0, label: "Review module", phaseIndex: 0, state: "running", tokens: 12_000 }],
                ]),
              }),
            ],
            1.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    "one-running": {
      note: "One subagent running: its line alone above the composer, its icon in the theme's accent, what it does now, its time and state.",
      play: trayLines(1),
      snapshot: chat(
        [
          user(prompt, 2),
          group([agent("Explain daemon update mechanism", 1.8, "running", { kind: "Explore", action: "Bash" })], 1.8),
          assistant("A subagent is reading the update code now; I'll report back when it is done.", 1.7),
        ],
        { isWorking: true },
      ),
    },
    "running-stop-solid": {
      note: 'The default running line (Leo, 2026-11-03: "do we really need a running symbol vs just having the time and a square stop button?"): its own mark, its task, its ticking time and a filled square Stop in the text colour, as Claude Desktop\'s Background tasks rows read; no spinner, no Running word. The done line keeps Done · its time.',
      play: runningStop("solid"),
      snapshot: runningStopChat,
    },
    "harness-identity": {
      note: "The dock keeps Claude and Codex harness marks in each row and the stacked header, with a stable toned sparkle fallback for an unknown harness.",
      play: async (ctx) => {
        await openTray(ctx);
        const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        const marks = tray.querySelectorAll('.acpmux-agent-line .acpmux-lineage__icon [data-identity-look="tint"]');
        if (marks.length !== 3) throw new Error(`expected three toned identity marks, got ${marks.length}`);
        const stack = tray.querySelector(".acpmux-running-tray__stack");
        if (!stack || stack.querySelectorAll(".acpmux-running-tray__stack-mark").length !== 3)
          throw new Error("the stacked header does not retain all three identity marks");
      },
      snapshot: harnessIdentityChat,
    },
    "running-stop-muted": {
      note: "The same running lines with the filled square Stop muted, the time's tone.",
      play: runningStop("muted"),
      snapshot: runningStopChat,
    },
    "running-stop-boxed": {
      note: "The same running lines with the filled square Stop on a faint 10% box, as the Background tasks panel draws its Stop.",
      play: runningStop("boxed"),
      snapshot: runningStopChat,
    },
    "row-menu": {
      note: "A running subagent has a fixed Stop square in its row track and the same action in its context menu. A right-click opens the menu on the click, and the line stays lit under it.",
      play: async (ctx) => {
        await trayLines(2)(ctx);
        await ctx.waitFor(() =>
          Boolean(ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line__stop-slot > button")),
        );
        await ctx.contextMenu({ selector: ".acpmux-running-tray .acpmux-agent-line__button" });
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll('[role="menu"] [role="menuitem"]')].some((item) =>
            item.textContent?.startsWith("Stop "),
          ),
        );
      },
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            [
              agent("Explain daemon update mechanism", 1.8, "running", { kind: "Explore", action: "Bash" }),
              agent("Review the fold", 1.6, "running", { kind: "general-purpose", action: "Read fold.ts" }),
            ],
            1.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    "duration-columns": {
      note: "Duration-column stress fixture: running work spans 9s, 2h 20m and 12h 59m 59s so every time stays on one line in the shared trailing track.",
      play: async (ctx) => {
        await trayLines(6)(ctx);
      },
      snapshot: chat(
        [
          user("Keep the long-running checks visible", 3),
          group(
            [
              durationAgent("Fresh check", 9_000, { action: "Run the quick check" }),
              durationAgent("Nested check", 59_000, { action: "Run the nested check", parent: "agent-fresh-check" }),
              durationAgent("Medium check", 31 * 60_000 + 19_000, { action: "Run the medium check" }),
              durationAgent("Long check", 2 * 60 * 60_000 + 20 * 60_000, { action: "Run the integration suite" }),
              durationAgent("Overnight check", 12 * 60 * 60_000 + 59 * 60_000 + 59_000, {
                action: "Review the overnight logs",
                command: "overnight-check",
              }),
            ],
            1,
          ),
          testRun,
        ],
        { isWorking: true },
      ),
    },
    "one-command": {
      note: "One background command: its line leads with its kind's mark (a test run's check, trayCommandKinds.ts) in place of the word Command, ends in a chevron (a click opens its output) and has no fill at rest; hover fills the whole line to the tray's edges, one inset. The whole shell line is its tooltip.",
      play: async (ctx) => {
        await trayLines(1)(ctx);
        if (ctx.document.querySelector(".acpmux-agent-line__kind"))
          throw new Error("a command's line leads with its kind's mark, not the word Command");
      },
      snapshot: chat([user("Run the red/green tests in the background", 59), testRun], { isWorking: true }),
    },
    "command-words": {
      note: 'Background commands read in words, not shell (Leo, 2026-11-03: "instead of raw things, we should be able to deterministically/heuristically have stuff"): built-in rules know only shapes anyone runs. A sleep reads Waiting 9m 20s, a merge Merging cmux#34769, a push Pushing its branch, bun test Testing its file, ssh On its host: what it runs there, docker compose Starting containers. The shell line is the tooltip; a line about a pull request links to it from its tail.',
      height: 560,
      play: async (ctx) => {
        await trayLines(RAW_COMMANDS.length)(ctx);
        const names = [...ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-summary-agent__name")].map(
          (name) => name.textContent,
        );
        for (const want of [
          "Waiting 9m 20s",
          "Merging cmux#34769",
          "Pushing lane/hat-command-labels",
          "Testing command-rules",
          "On build-host: Testing acpmux",
          "Starting containers",
        ])
          if (!names.includes(want)) throw new Error(`a command reads "${want}", got ${names.join(" | ")}`);
        if (names.some((name) => name?.includes("--"))) throw new Error("no line shows a raw shell line");
      },
      snapshot: chat([user("Wait, land it, push and run the tests", 7), rawCommands], {
        isWorking: true,
      }),
    },
    "command-words-preset": {
      note: "With cmux-next.json's agentPane.display.commandLabels set to [\"cmux-fleet\", a deploy rule], the fleet preset names the session and cmux-ci lines (Starting Tray command labels, Fleet tests · Playwright, Fleet run for #34769) and the person's own rule names deploy (Deploying staging). Without it they read by program and main argument, as cmux-ci test.",
      height: 480,
      display: {
        "agentPane.display.commandLabels": [
          "cmux-fleet",
          { program: "deploy", match: "^deploy (\\S+)", label: "Deploying {1}", icon: "cloud" },
        ],
      },
      play: async (ctx) => {
        await trayLines(FLEET_COMMANDS.length)(ctx);
        const names = [...ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-summary-agent__name")].map(
          (name) => name.textContent,
        );
        for (const want of [
          "Starting Tray command labels",
          "Fleet tests · Playwright",
          "Fleet run for #34769",
          "Deploying staging",
        ])
          if (!names.includes(want)) throw new Error(`a command reads "${want}", got ${names.join(" | ")}`);
      },
      snapshot: chat([user("Wait on the checks, run the fleet tests and deploy", 5), fleetCommands], {
        isWorking: true,
      }),
    },
    "command-substitution": {
      note: "Leo's raw rev-parse HEAD); strip, repaired: git rev-parse HEAD · cmux-ci run: the setup's substitution stays named, then the program that does the work (session-info/commandWorkLabel.ts; the cmux-fleet preset would read it as Fleet run). Shell flags and interpolation remain in the full-command tooltip.",
      snapshot: glyphCheckScene(),
      play: async (ctx) => {
        await trayLines(1)(ctx);
        const name = ctx.document.querySelector(".acpmux-running-tray .acpmux-summary-agent__name");
        if (name?.textContent !== "git rev-parse HEAD · cmux-ci run")
          throw new Error("the command needs a readable title");
        const line = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray .acpmux-agent-line__button");
        if (line?.title !== glyphCheck) throw new Error("the full command stays available in the tooltip");
      },
    },
    "command-substitution-described": {
      note: "The same shell line with a human description: the tray uses that title unchanged.",
      snapshot: glyphCheckScene("Check the glyphs on the fleet"),
      play: trayLines(1),
    },
    "command-substitution-folded": {
      note: "The command shares the tray with a reviewer. Its readable title also appears in the folded name arm; no malformed assignment leaks into the strip.",
      snapshot: chat(
        [
          user("Check the glyphs on the fleet", 9),
          group([agent("Review glyph changes", 9)], 9),
          ...glyphCheckScene().rows.slice(1),
        ],
        { isWorking: true },
      ),
    },
    "expand-on-composer": {
      note: "Chosen (Leo, 2026-11-01: \"there's a layout shift when i expand it\"): the tray stays on the composer, its columns on the composer's. What it opens lies over the transcript's foot, as a menu over the composer does, and no row moves; the room under the last row takes it once the rows move anyway (a reply streaming on, a send, Jump to latest, or the reader's wheel past the end).",
      height: 420,
      snapshot: panel(3, 2, EARLIER),
      play: expandTray("composer"),
    },
    "expand-after-latest": {
      note: "Alternative, not chosen: the tray attached under the latest message. At the end, opening it pushes the whole transcript up by what opened (as a tool call opened at the bottom does); away from the end it opens below the view. Nothing on the composer, but the tray's columns no longer line up with the composer's Stop and microphone.",
      height: 420,
      theme: { subagentTrayPlacement: "after-latest-message" },
      snapshot: panel(3, 2, EARLIER),
      play: expandTray("after-latest"),
    },
    "after-latest-message": {
      note: "Labs/fixture placement: the running command tray sits directly after the latest message while the default remains above the composer. A click opens the command's row; its live tail needs a connected process source, which the gallery has none of.",
      theme: { subagentTrayPlacement: "after-latest-message" },
      play: async (ctx) => {
        await trayLines(1)(ctx);
        const tray = ctx.document.querySelector<HTMLElement>(".acpmux-transcript-after-latest .acpmux-running-tray");
        if (!tray) throw new Error("after-latest placement must stay in the transcript flow");
        const dock = ctx.document.querySelector<HTMLElement>(".acpmux-dock");
        const reserve = ctx.document.querySelector<HTMLElement>(".acpmux-transcript-after-latest");
        if (dock && reserve && reserve.getBoundingClientRect().bottom > dock.getBoundingClientRect().top + 1)
          throw new Error("after-latest tray must remain above the full dock");
        await ctx.click({ selector: ".acpmux-running-tray .acpmux-agent-line__button" });
        await ctx.waitFor(() => {
          const row = ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line__button");
          return row?.getAttribute("aria-expanded") === "true";
        });
      },
      snapshot: chat([user("Run the red/green tests in the background", 59), testRun], { isWorking: true }),
    },
    "plan-and-commands": {
      note: 'Leo\'s composer hat with the turn\'s todo list (2026-11-03: "we said earlier the composer hat is kinda ok?"): folded, it reads "2 of 5 · <the step at work>" before the newest command, "+2 more" and the time; the transcript holds no list while the turn runs.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent ?? "";
        if (!title.startsWith("2 of 5 · Run the tray tests")) throw new Error(`unexpected hat: ${title}`);
        if (ctx.document.querySelector(".cv-plan:not(.acpmux-running-tray .cv-plan)"))
          throw new Error("the running list is in the hat, not the transcript");
      },
      snapshot: planChat(),
    },
    "plan-and-commands-open": {
      note: "The same hat opened: the checklist first, then a line per background command.",
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .cv-plan__item").length === 5);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
      },
      snapshot: planChat(),
    },
    "plan-short-dock": {
      note: "The opened hat in a dock with room for the header and about three rows: the checklist and the command lines share that height, each scrolling in place, so a command's Stop stays reachable.",
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
        const dock = ctx.document.querySelector<HTMLElement>(".acpmux-dock")!;
        const composer = dock.querySelector<HTMLElement>(".acpmux-composer")!;
        const header = dock.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
        const rows = 3 * header.getBoundingClientRect().height;
        dock.style.maxHeight = `${composer.getBoundingClientRect().height + header.getBoundingClientRect().height + rows}px`;
        const shown = (selector: string) => {
          const tray = ctx.document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
          const box = ctx.document.querySelector(selector)!.getBoundingClientRect();
          return Math.min(box.bottom, tray.bottom) - Math.max(box.top, tray.top);
        };
        await ctx.waitFor(() => shown(".acpmux-running-tray__plan") > 0 && shown(".acpmux-running-tray__list") > 0);
      },
      snapshot: planChat(),
    },
    "several-running": {
      note: "Two subagents and a background command: a header with the counts and the time since the first started, a line each once its header is opened (it starts folded to the header). The ended task remains a compact status card.",
      play: trayLines(3),
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            [
              agent("Read the updater", 1.9, "running", { kind: "Explore", action: "Read Sources/Updater.swift" }),
              agent("Check the docs", 1.9, "running", { kind: "general-purpose", action: "Read docs/updates.md" }),
              agent("Find the release script", 1.9, "completed", { kind: "Explore", ran: 0.6 }),
            ],
            1.9,
          ),
          devServer,
          assistant("Two subagents are on it, and the dev server is up.", 1.2),
        ],
        { isWorking: true },
      ),
    },
    "command-and-subagent": {
      note: "A turn with a subagent and a background command: a header with both counts, then a line each; the working line counts nothing, the tray is the count.",
      play: async (ctx) => {
        await trayLines(2)(ctx);
        if (ctx.document.querySelector(".cv-worked__open")) throw new Error("the tray is the count, not the line");
      },
      snapshot: chat(
        [
          user("Start the dev server, then have a subagent check the routes", 2),
          devServer,
          group([agent("Check the routes", 1.2, "running", { kind: "Explore", action: "Read src/routes.ts" })], 1.2),
        ],
        { isWorking: true },
      ),
    },
    "one-agent-two-commands": {
      note: "One subagent and two background commands, opened: the header reads exactly `1 subagent running · 1 test run · 1 build` above its lines, the commands counted by what they do (folded, it names them: agent-pane.subagent-tray-names).",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (title !== "1 subagent running · 1 test run · 1 build") throw new Error(`unexpected tray title: ${title}`);
      },
      snapshot: chat(
        [
          user("Start the checks and have one reviewer inspect the tray", 2),
          group([agent("Inspect the tray", 1.6, "running", { kind: "Explore", action: "Read SubagentTray.tsx" })], 1.6),
          described,
        ],
        { isWorking: true },
      ),
    },
    "between-turns": {
      note: "After the turn: a background subagent and two chats the agent started still run. The tray says so above the composer; the transcript ends with the turn's footer.",
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
        if (ctx.document.querySelector(".cv-bgwork")) throw new Error("no Running in background row in the transcript");
      },
      snapshot: (() => {
        const base = chat([
          user("Split the migration into two chats and keep an eye on the logs", 7),
          group([agent("Watch the logs", 6.5, "running", { kind: "general-purpose", background: true })], 6.5),
          assistant("Two chats are migrating the settings store and the history page; a subagent watches the logs.", 5),
          summary(5, { status: "completed", durationMs: 70_000, toolCount: 1 }),
        ]);
        return {
          ...base,
          sessions: [
            ...base.sessions,
            session({
              sessionId: "child-1",
              title: "Migrate the settings store to SQLite",
              spawnedBy: SESSION_ID,
              startedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.5),
            }),
            session({
              sessionId: "child-2",
              title: "Port the history page to React Aria",
              spawnedBy: SESSION_ID,
              startedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.4),
            }),
          ],
        };
      })(),
    },
    "dispatched-lane": {
      note: 'Leo, 2026-11-03, on a lane a coordinator dispatched showing as a running line: "like why is this even in the "running" in the first place?" The tray lists only the chat\'s own work: its subagent\'s line, never the lane (started with sessions new, tagged mux.parent, no startedBy), which is its own chat in the sidebar.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
        const lines = ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line");
        if (lines.length !== 1) throw new Error(`one line, the chat's own subagent; got ${lines.length}`);
        if ((ctx.document.querySelector(".acpmux-running-tray")?.textContent ?? "").includes("mac-studio-ultras"))
          throw new Error("a dispatched lane is never a running line");
      },
      snapshot: (() => {
        const base = chat(
          [
            user("Audit the stack, and place a lane for the Mac Studio work", 3),
            group(
              [agent("Audit the bottom stack", 2.5, "running", { kind: "Explore", action: "Read bottomStack.css" })],
              2.5,
            ),
            assistant("An auditor is on the stack; the Mac Studio lane is placed.", 2),
          ],
          { isWorking: true },
        );
        return {
          ...base,
          sessions: [
            ...base.sessions,
            session({
              sessionId: "lane-mac-studio",
              title: "mac-studio-ultras",
              name: "mac-studio-ultras",
              spawnedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              lane: "working",
              createdAt: minutesAgo(2),
            }),
          ],
        };
      })(),
    },
    "counts-equal-rows": {
      note: "What Leo called lying, told straight: the header counts what runs kind by kind (2 subagents, 2 sessions it started, a test run and a build), then the 3 that ended in the list, and equals the rows under it. A command reads as what it does, not its cd prefix; a chat says what its turn does now. What ended stays visible as bounded status cards.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 3);
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        // Kind by kind (trayHeadKinds.ts): the chats it started read as sessions, and what ended in
        // the list counts after what runs.
        if (title !== "2 subagents running · 2 sessions · 1 test run · 1 build · 3 done")
          throw new Error(`the header must count the rows: ${title}`);
      },
      snapshot: (() => {
        const base = chat(
          [
            user("Land the tray fix: two reviewers, the fleet compile and the tests", 3),
            group(
              [
                agent("Review the tray counts", 2.8, "running", {
                  kind: "general-purpose",
                  action: "Read runningTray.ts",
                }),
                agent("Review the fold", 2.8, "running", { kind: "general-purpose", action: "Grep subagent_progress" }),
                agent("Find the screenshot", 2.8, "completed", { kind: "Explore", ran: 0.4 }),
              ],
              2.8,
            ),
            described,
            assistant("Two reviewers are on it, the compile and the tests run, and two chats port the rest.", 1.2),
          ],
          { isWorking: true },
        );
        return {
          ...base,
          sessions: [
            ...base.sessions,
            child("child-1", "Port the history page to React Aria", 2.5, true, "Run bun test"),
            child("child-2", "Migrate the settings store to SQLite", 2.4, true, "Edit store.ts"),
            child("child-3", "Fix the dock hover", 9, false),
            child("child-4", "Draft the release notes", 8, false),
          ],
        };
      })(),
    },
    "codex-lineage": {
      note: 'A Codex chat\'s subagents as its records say (Leo 2026-10-22: "why is it like... staggered? were they created by another subagent?"): the chat itself started both, so they sit side by side. A child that reports its parent thread never makes the chat a subagent of its own, nested under that child.',
      play: async (ctx) => {
        await openTray(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
        const names = [...ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-summary-agent__name")];
        if (names.some((name) => /^[0-9a-f]{8}-/.test(name.textContent ?? "")))
          throw new Error("the chat is not one of its own subagents");
      },
      snapshot: chat(
        [
          user("Review the Needs you work and find prior art", 22.6),
          group(codexLineage(), 22.2),
          assistant("Two reviewers are on it.", 21),
        ],
        { isWorking: true, harness: "codex" },
      ),
    },
    "many-folded": {
      note: "Five running: the tray starts folded to its header so it never takes the transcript's room; the chevron opens the list.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        if (ctx.find({ selector: ".acpmux-running-tray__head" }).getAttribute("aria-expanded") !== "false")
          throw new Error("a headed tray starts folded");
      },
      snapshot: chat(
        [
          user("Review each package for unused exports", 2),
          group(
            ["net", "ui", "store", "router", "i18n"].map((name, index) =>
              agent(`Package ${name}`, 1.9 - index * 0.1, "running", { action: `Read src/${name}/index.ts` }),
            ),
            1.9,
          ),
        ],
        { isWorking: true },
      ),
    },
    "finished-line": {
      note: "A finished turn, its Worked for opened: each subagent left one quiet line where it ended, with its name and how long it ran; no tray.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent-done").length === 2);
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("nothing runs: no tray");
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Explain daemon update mechanism", 11.8, "completed", { ran: 1.3 }),
            agent("Check the docs", 11.8, "completed", { ran: 2.1 }),
          ],
          11.8,
        ),
        assistant("The daemon updates itself on launch; the docs agree except for the channel name.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    "failed-line": {
      note: "A subagent that failed says so in the danger color. A stopped one says why when the pane knows: the person stopped it (Stop), or a Send now interrupted its turn; one stopped for a reason the pane cannot know (another client's cancel, Claude's own TaskStop) says none rather than guess. One that did not finish offers Restart on hover.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('.cv-subagent-done[data-state="failed"]'));
        const texts = [...ctx.document.querySelectorAll(".cv-subagent-done")].map((line) => line.textContent ?? "");
        if (!texts.some((text) => text.includes("stopped by you")))
          throw new Error("a subagent the person stopped says so");
        if (!texts.some((text) => text.includes("interrupted by Send now")))
          throw new Error("a subagent a Send now stopped says so");
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Run the update tests", 11.8, "failed", { ran: 0.8, prompt: "Run the updater's tests" }),
            agent("Check the docs", 11.8, "cancelled", {
              ran: 1.6,
              stopReason: "user",
              prompt: "Check docs/updates.md",
            }),
            agent("Read the release script", 11.8, "cancelled", {
              ran: 1.9,
              stopReason: "sendNow",
              kind: "Explore",
              prompt: "Read scripts/release.sh",
            }),
            agent("Find the channel name", 11.8, "cancelled", { ran: 2.2 }),
          ],
          11.8,
        ),
        assistant("The update tests failed to start; the other checks were stopped.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    "restart-on-hover": {
      note: "Restart on a stopped subagent's line, shown on hover or keyboard focus (focused here): the hover row's compact button, its name and what it does on hover. It asks the chat to run the subagent again with its prompt.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-restart"));
        (ctx.document.querySelector(".cv-subagent-restart") as HTMLButtonElement).focus();
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Check the docs", 11.8, "cancelled", {
              ran: 1.6,
              stopReason: "user",
              kind: "Explore",
              prompt: "Check docs/updates.md",
            }),
          ],
          11.8,
        ),
        assistant("Stopped the docs check.", 9),
        summary(9, { status: "cancelled", durationMs: 110_000 }),
      ]),
    },
  },
});
