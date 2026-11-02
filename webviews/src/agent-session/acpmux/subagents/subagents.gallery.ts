// l10n-allow-file: gallery fixtures (sample prompts, subagent names and tasks), not shipped UI.
// With Debug Settings agentPane.debug.subagentTray off (the tray above the composer is the default,
// SubagentTray.gallery.ts), a batch of subagents inline in the transcript (SubagentGroup.tsx): the group row in each state,
// as the snapshot rows the pane receives after direct.ts folds a session's subagent updates; an
// open group's list (SubagentListRow), opened by a click; and the summary card at the pane's top
// right (summary/SummaryCard.tsx), which lists them with their live state from the same groups. In
// the gallery's widths the pane has no room for the card's inline column (summary/cardState.ts,
// #21564), so the card is the popover the header's Summary button opens, and a click outside it
// closes it; a pane wide enough shows the column on its own, and it stays. A list line opens that subagent's own view (the child view): a "Subagent of" pill naming its
// parent, then its rows, nested groups included. A pane the app opened on a subagent shows it read
// only: a line naming the chat where the composer would be (SubagentPaneFooter.tsx).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

/** A call the pane made to the host, as the gallery logs it. */
type PaneCall = { method: string; params?: { subagent?: string; focus?: boolean } };

const prompt = "Audit the fetch helper: retries, errors, timeouts and tests";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.5, ...rest } = fields;
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

const AUDIT = ["Retry policy", "Error parsing", "Timeouts", "Test coverage"];

const MIXED = chat(
  [
    user(prompt, 4),
    group(
      [
        agent("Retry policy", 3.8, "completed", { ran: 1.2 }),
        agent("Error parsing", 3.8, "completed", { ran: 2 }),
        agent("Timeouts", 3.8, "failed", { ran: 0.6 }),
        agent("Test coverage", 3.8, "running", { action: "bun test src/net" }),
      ],
      3.8,
    ),
  ],
  { isWorking: true },
);

const PACKAGES = ["net", "ui", "store", "router", "i18n", "icons", "tests"];
const MANY = chat(
  [
    user("Review each package for unused exports", 3),
    group(
      PACKAGES.map((name, index) =>
        agent(`Package ${name}`, 2.9, index < 3 ? "completed" : "running", { ran: 0.5 + index * 0.2 }),
      ),
      2.9,
    ),
  ],
  { isWorking: true },
);

const DONE = chat([
  user(prompt, 12),
  group(
    AUDIT.map((name, index) => agent(name, 11.8, "completed", { ran: 1 + index * 0.5 })),
    11.8,
  ),
  assistant("All four areas are covered. Two timeouts are too short; the rest is fine.", 9),
  summary(9, { status: "completed", durationMs: 180_000 }),
]);

/** The mixed group's running "Test coverage" subagent with a view of its own: a thought and
 * tool calls, a nested group it spawned, and its text. */
const COVERAGE = "agent-test-coverage";
const NESTED = [
  agent("Unit tests", 3.2, "completed", { parent: COVERAGE, ran: 1.1 }),
  agent("Integration tests", 3.2, "running", { parent: COVERAGE, action: "bun test src/net/fetch" }),
];
const NESTED_MIXED: typeof MIXED = {
  ...MIXED,
  subagentViews: {
    [COVERAGE]: [
      activity(
        [
          thought("Which tests cover retries and timeouts today?"),
          tool("Read src/net/fetch.test.ts", "read", "completed"),
          tool("Search for timeout in src/net", "search", "completed"),
        ],
        3.6,
        { id: `${COVERAGE}:activity-1` },
      ),
      assistant("Retries have no tests. Splitting unit and integration coverage.", 3.3, {
        id: `${COVERAGE}:assistant-2`,
      }),
      group(NESTED, 3.2),
    ],
    [NESTED[0]!.id]: [assistant("Added four retry cases; all pass.", 2.1, { id: `${NESTED[0]!.id}:assistant-1` })],
  },
};

/** Codex subagents as codex-acp sends them once acpmux asks for native subagent sessions
 * (cx-07ezn, recorded on a fleet Mac 2026-10-12): named from their agent path ("Read a"), each
 * with its own read and reply; Codex's `wait` calls between them draw no row. */
const CODEX_A = agent("Read a", 1.6, "completed", { ran: 0.4 });
const CODEX_B = agent("Read b", 1.6, "running", { action: "Read file 'b.txt'" });
const CODEX = {
  ...chat(
    [
      user("Spawn two subagents: one reads a.txt, one reads b.txt. Combine their answers.", 1.7),
      group([CODEX_A, CODEX_B], 1.6),
    ],
    { isWorking: true, harness: "codex", model: "gpt-6-astra", title: "Read a.txt and b.txt" },
  ),
  subagentViews: {
    [CODEX_A.id]: [
      activity([tool("Read file 'a.txt'", "read", "completed")], 1.5, { id: `${CODEX_A.id}:activity-1` }),
      assistant("a.txt says alpha.", 1.3, { id: `${CODEX_A.id}:assistant-2` }),
    ],
    [CODEX_B.id]: [
      activity([tool("Read file 'b.txt'", "read", "in_progress")], 1.5, { id: `${CODEX_B.id}:activity-1` }),
    ],
  },
};

/** Claude subagents name the kind of agent each one is (its Agent call's subagent_type). */
const CLAUDE_KINDS = chat(
  [
    user("Find where retries are configured and check the docs agree", 2),
    group(
      [
        agent("Find retry config", 1.9, "completed", { kind: "Explore", ran: 0.7 }),
        agent("Check the docs", 1.9, "running", { kind: "general-purpose", action: "Read docs/net.md" }),
        agent("Review naming", 1.9, "running", { kind: "code-reviewer", action: "Search for retryCount" }),
      ],
      1.9,
    ),
  ],
  { isWorking: true },
);

/** A Codex turn whose running subagent asks for a permission: the card says it waits on the user. */
const WAITING = {
  ...CODEX,
  permission: {
    permissionId: "perm-read-b",
    toolCallId: CODEX.subagentViews[CODEX_B.id]![0]!.items![0]!.tool!.id,
    title: "Read file 'b.txt'",
    kind: "read",
    pending: true,
    options: [
      { id: "allow", name: "Allow", allow: true },
      { id: "reject", name: "Reject", allow: false },
    ],
  },
};

/** Shows the summary card from the header's Summary button unless it shows already (a pane wide
 * enough for its inline column shows it on its own), and waits for its Subagents list. */
const openSummary = async (ctx: PlayContext) => {
  if (ctx.find({ selector: ".acpmux-summary-button" }).getAttribute("aria-pressed") !== "true")
    await ctx.click({ selector: ".acpmux-summary-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-agents"));
};

/** Runs `play` with the summary card's Open subagents in panes switch on: only then does a click
 * open a pane. The switch lives in the frame's localStorage, shared by every variant in the same
 * browser, so it is cleared afterwards, else each later agent-pane variant starts with it on. */
const withPanes = (play: (ctx: PlayContext) => Promise<void>) => async (ctx: PlayContext) => {
  try {
    await openSummary(ctx);
    const toggle = ctx.find({ selector: ".acpmux-summary-autoopen input" }) as HTMLInputElement;
    if (!toggle.checked) await ctx.click({ selector: ".acpmux-summary-autoopen input" });
    await ctx.waitFor(() => toggle.checked);
    await play(ctx);
  } finally {
    ctx.document.defaultView?.localStorage.removeItem("cmux.acpmux.subagentPanes");
  }
};

/** The card's row for subagent `name`. */
const cardRow = (ctx: PlayContext, name: string) =>
  [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-summary-card .acpmux-summary-agent")].find(
    (node) => node.querySelector(".acpmux-summary-agent__name")?.textContent === name,
  );

/** Opens the first group, then `name`'s own view. */
const openChild = (name: string) => async (ctx: PlayContext) => {
  await openGroup(4)(ctx);
  await ctx.click({ role: "button", name: `Open ${name}` });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of"));
};

/** Opens the first group and waits for its `count` subagent lines. A group of running agents in a
 * working turn is open already (App.tsx), and stays so. */
const openGroup = (count: number) => async (ctx: PlayContext) => {
  await ctx.focus({ selector: ".cv-subagents" });
  if (ctx.find({ selector: ".cv-subagents" }).getAttribute("aria-expanded") !== "true") await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent").length === count);
  const disclosure = ctx.find({ selector: ".cv-subagents" });
  const controls = disclosure.getAttribute("aria-controls")?.split(" ").filter(Boolean) ?? [];
  if (controls.length !== count)
    throw new Error(`subagent disclosure controls ${controls.length} rows, expected ${count}`);
  if (controls.some((id) => !ctx.document.getElementById(id)))
    throw new Error("subagent disclosure controls a row that is not rendered");
  if (ctx.document.activeElement !== disclosure) throw new Error("subagent disclosure lost focus while opening");
};

/** These variants show the group card in the transcript and the agents pill, which Debug Settings
 * agentPane.debug.subagentTray off keeps; the tray, the default, is SubagentTray.gallery.ts. The
 * summary card is the same either way. */
const groupCards = (variants: Record<string, AgentPaneVariant>): Record<string, AgentPaneVariant> =>
  Object.fromEntries(
    Object.entries(variants).map(([name, variant]) => [
      name,
      { ...variant, theme: { subagentTray: false, ...variant.theme } },
    ]),
  );

export default agentPaneEntry({
  id: "agent-pane.subagents",
  title: "Subagents",
  area: "Agent pane",
  height: 420,
  // The header and the composer stay put while a group opens below or a popover opens over them.
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentGroup.tsx",
    "agent-session/acpmux/subagents/AgentsPill.tsx#AgentsPill",
    "agent-session/acpmux/subagents/SubagentPaneFooter.tsx#SubagentPaneFooter",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
    "agent-session/acpmux/summary/SummaryCard.tsx#SummaryCard",
    "agent-session/acpmux/summary/SummaryBody.tsx#SummaryBody",
    "agent-session/acpmux/summary/SummarySection.tsx#SummarySection",
    "agent-session/acpmux/summary/SubagentStack.tsx#SubagentStack",
    "agent-session/acpmux/summary/SubagentStatusList.tsx#SubagentStatusList",
  ],
  variants: groupCards({
    "agents-pill": {
      note: "The agents pill while two of four subagents run (after Codex's phone app). It opens Active and Completed, a dot per agent in the color its name has in the open group; a click on an agent opens it.",
      height: 640,
      snapshot: MIXED,
    },
    running: {
      note: "Four subagents started together, all still working: the group is open, a line per agent, with no click.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent").length === AUDIT.length);
        if (ctx.find({ selector: ".cv-subagents" }).getAttribute("aria-expanded") !== "true")
          throw new Error("a group of running agents in a working turn must start open");
      },
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            AUDIT.map((name) => agent(name, 1.8, "running", { action: `Read ${name.toLowerCase()} code` })),
            1.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    mixed: { note: "Some done, one failed, one still working: open while it works.", snapshot: MIXED },
    codex: {
      note: "Codex subagents (native sessions through codex-acp, cx-07ezn): Codex marks, names from the agent path.",
      snapshot: CODEX,
      play: openGroup(2),
    },
    "codex-child": {
      note: "A Codex subagent's own view: its read, as Codex streams it under the child's session.",
      snapshot: CODEX,
      play: async (ctx) => {
        await openGroup(2)(ctx);
        await ctx.click({ role: "button", name: "Open Read a" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of"));
      },
    },
    "codex-two-turns": {
      note: "A Codex chat with subagents, then a second prompt: nothing stray beside the second turn (nxdog96).",
      height: 560,
      snapshot: {
        ...CODEX,
        rows: [
          ...CODEX.rows,
          assistant("a.txt says alpha and b.txt says beta.", 1.1),
          summary(1.1, { status: "completed", durationMs: 40_000 }),
          user("Now count the words in both files.", 0.8),
        ],
      },
    },
    "claude-kinds": {
      note: "Claude subagents with their kind (Explore, general-purpose, a user agent) beside the name.",
      snapshot: CLAUDE_KINDS,
      play: openGroup(3),
    },
    single: {
      note: "One subagent: no avatar stack overflow, singular count.",
      snapshot: chat([user("Find every caller of request()", 1), group([agent("Find callers", 0.9)], 0.9)], {
        isWorking: true,
      }),
    },
    many: { note: "Seven subagents: three avatars, then +4; open while they work.", snapshot: MANY },
    done: { note: "An ended turn: the group stays in view above the reply, outside Worked for.", snapshot: DONE },
    stopped: {
      note: "A turn stopped while subagents ran: cancelled and disconnected.",
      snapshot: chat([
        user(prompt, 6),
        group(
          [
            agent("Retry policy", 5.8, "completed", { ran: 0.8 }),
            agent("Error parsing", 5.8, "cancelled", { ran: 1.1 }),
            agent("Timeouts", 5.8, "disconnected", { ran: 0.4 }),
          ],
          5.8,
        ),
        summary(4.7, { status: "cancelled" }),
      ]),
    },
    "stopped-open": {
      note: "The stopped group opened: one done, one cancelled, one disconnected; the line counts the two as stopped.",
      snapshot: chat([
        user(prompt, 6),
        group(
          [
            agent("Retry policy", 5.8, "completed", { ran: 0.8 }),
            agent("Error parsing", 5.8, "cancelled", { ran: 1.1 }),
            agent("Timeouts", 5.8, "disconnected", { ran: 0.4 }),
          ],
          5.8,
        ),
        summary(4.7, { status: "cancelled" }),
      ]),
      play: async (ctx) => {
        await openGroup(3)(ctx);
        const line = ctx.find({ selector: ".cv-subagents__title" }).textContent;
        if (line !== "3 subagents, 2 stopped, 1 done") throw new Error(`group line reads ${line}`);
        const states = [...ctx.document.querySelectorAll(".cv-subagent__state")].map(
          (node) => node.textContent?.split(" · ")[0],
        );
        if (states.join("|") !== "Done|Cancelled|Disconnected") throw new Error(`rows read ${states.join("|")}`);
      },
    },
    "two-batches": {
      note: "Text between spawns starts a second group.",
      snapshot: chat(
        [
          user(prompt, 8),
          group([agent("Retry policy", 7.8, "completed"), agent("Error parsing", 7.8, "completed", { ran: 2 })], 7.8),
          assistant("Both reviews are in. Now checking timeouts and tests in parallel.", 5.6),
          group([agent("Timeouts", 5.5), agent("Test coverage", 5.5, "running", { action: "bun test src/net" })], 5.5),
        ],
        { isWorking: true },
      ),
    },
    open: {
      note: "The mixed group opened: a line per subagent with its state or current action.",
      snapshot: MIXED,
      play: openGroup(4),
    },
    "open-many": {
      note: "Seven subagents opened: the list grows below, the lines above stay put.",
      height: 640,
      snapshot: MANY,
      play: openGroup(PACKAGES.length),
    },
    "open-done": {
      note: "An ended turn's group opened: the reply below moves down without a layout shift.",
      snapshot: DONE,
      play: openGroup(AUDIT.length),
    },
    child: {
      note: "A list line opened: the subagent's own view, under a Subagent of pill naming the chat.",
      height: 640,
      snapshot: NESTED_MIXED,
      play: openChild("Test coverage"),
    },
    "child-nested": {
      note: "A nested group in the child view opened, then its finished subagent: the pill names its parent.",
      height: 760,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        // The nested group of a running agent starts open in the working turn.
        if (ctx.find({ selector: ".cv-subagents" }).getAttribute("aria-expanded") !== "true")
          await ctx.click({ selector: ".cv-subagents" });
        await ctx.click({ role: "button", name: "Open Unit tests" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of__parent")?.textContent === "Test coverage");
      },
    },
    "child-back": {
      note: "The pill goes back to the parent: the chat's transcript, its group still open.",
      height: 680,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        await ctx.click({ selector: ".cv-subagent-of__pill" });
        await ctx.waitFor(
          () => !ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".cv-subagent"),
        );
      },
    },
    "own-pane": {
      note: "A pane the app opened on a subagent (a subagent: reveal): its view, read only, with a line naming the chat in place of the composer.",
      height: 640,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
        page.cmuxAcpmuxBridge?.revealTurn?.(`subagent:${COVERAGE}`);
        await ctx.waitFor(
          () => ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".cv-subagent-pane-footer"),
        );
        if (ctx.document.querySelector(".acpmux-composer")) throw new Error("a subagent's own pane drew the composer");
      },
    },
    summary: {
      note: "The summary card the Summary button opens at the top right: every subagent with its state and time: waiting, then running, then ended.",
      snapshot: MIXED,
      play: openSummary,
    },
    "summary-legacy": {
      note: "A chat recorded before acpmux reported subagents: Claude's Task calls as the Subagents stack.",
      snapshot: chat([
        user(prompt, 6),
        activity(
          [
            tool("Audit retry policy", "think", "completed"),
            tool("Audit error parsing", "think", "completed"),
            tool("Audit timeouts", "think", "failed"),
          ],
          5.8,
        ),
        assistant("Two of three audits finished; the timeouts audit failed.", 4),
      ]),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-summary-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-subagents"));
      },
    },
    "card-outside-click": {
      note: "A click in the transcript closes the popover card (a pane too narrow for its inline column); the inline column would stay.",
      snapshot: MIXED,
      play: async (ctx) => {
        await openSummary(ctx);
        const inline = ctx.find({ selector: ".acpmux-summary-card" }).getAttribute("data-placement") === "inline";
        await ctx.click({ selector: ".acpmux-scroll" });
        if (inline) {
          if (!ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-agents"))
            throw new Error("a click outside the inline summary column closed it");
          return;
        }
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-summary-card"));
        if (ctx.find({ selector: ".acpmux-summary-button" }).getAttribute("aria-pressed") === "true")
          throw new Error("the Summary button still reads pressed after the popover closed");
      },
    },
    "card-collapsed": {
      note: "The card folded to its header: the subagents' live counts stay in view.",
      snapshot: MIXED,
      play: async (ctx) => {
        await openSummary(ctx);
        await ctx.click({ selector: ".acpmux-summary-card__fold" });
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".acpmux-summary-card__body") &&
            ctx.document.querySelector(".acpmux-summary-card__counts"),
        );
      },
    },
    "card-closed": {
      note: "The card's close button hides it; the header's summary button shows it again.",
      snapshot: MIXED,
      play: async (ctx) => {
        await openSummary(ctx);
        await ctx.click({ selector: ".acpmux-summary-card__close" });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-summary-card"));
        await ctx.click({ selector: ".acpmux-summary-button" });
        await openSummary(ctx);
      },
    },
    "card-waiting": {
      note: "A running Codex subagent asks for a permission: its row and the counts say Waiting.",
      snapshot: WAITING,
      play: async (ctx) => {
        await openSummary(ctx);
        await ctx.waitFor(() => cardRow(ctx, "Read b")?.dataset.status === "waiting");
      },
    },
    "card-kinds": {
      note: "Claude subagents in the card: each kind beside its name.",
      snapshot: CLAUDE_KINDS,
      play: openSummary,
    },
    "pane-open": {
      note: "With Open subagents in panes on and a host that opens them: a group line asks the app for the subagent's pane right of the chat, focused; this pane keeps the chat.",
      snapshot: CODEX,
      native: { "chat.subagentPane": { opened: true } },
      play: withPanes(async (ctx) => {
        await ctx.click({ selector: ".acpmux-summary-button" });
        await openGroup(2)(ctx);
        await ctx.click({ role: "button", name: "Open Read b" });
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: PaneCall[] }).cmuxGalleryLog;
        await ctx.waitFor(() =>
          log.some((call) => call.method === "chat.subagentPane" && call.params?.subagent === CODEX_B.id),
        );
        const call = log.find((entry) => entry.method === "chat.subagentPane");
        if (call?.params?.focus !== true) throw new Error("a click must focus the subagent's pane");
        if (ctx.document.querySelector(".cv-subagent-of")) throw new Error("the chat pane switched to the subagent");
      }),
    },
    "card-open-pane": {
      note: "A card row with Open subagents in panes on: the app shows that subagent's pane; the card stays.",
      snapshot: CODEX,
      native: { "chat.subagentPane": { opened: true } },
      play: withPanes(async (ctx) => {
        await ctx.click({ selector: '.acpmux-summary-agent[title="Read a"]' });
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: PaneCall[] }).cmuxGalleryLog;
        await ctx.waitFor(() =>
          log.some((call) => call.method === "chat.subagentPane" && call.params?.subagent === CODEX_A.id),
        );
        if (!ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-agents"))
          throw new Error("the card closed");
      }),
    },
    "card-open-child": {
      note: "A card row shows that subagent: its own view, its row marked current; nested ones indented.",
      height: 640,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openSummary(ctx);
        await ctx.click({ selector: '.acpmux-summary-agent[title="Test coverage"]' });
        await ctx.waitFor(
          () => ctx.document.querySelector(".cv-subagent-of") && cardRow(ctx, "Test coverage")?.ariaCurrent === "true",
        );
      },
    },
  }),
});
