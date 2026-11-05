// l10n-allow-file: gallery fixtures (sample prompts, subagent names and tasks), not shipped UI.
// A chat's subagents outside the running tray (SubagentTray.gallery.ts has the tray): the summary
// card at the pane's top right (summary/SummaryCard.tsx), which lists them with their live state from the same groups. In
// the gallery's widths the pane has no room for the card's inline column (summary/cardState.ts,
// #21564), so the card is the popover the header's Summary button opens, and a click outside it
// closes it; a pane wide enough shows the column on its own, and it stays. A card row opens that subagent's own view (the child view): a "Subagent of" pill naming its
// parent, then its rows. A pane the app opened on a subagent shows it with
// its own composer (SubagentComposer.tsx): "Message <subagent>", and a line naming the chat that
// passes the message on, where the chat's composer would be.
import { agentPaneEntry } from "../../../gallery/format";
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

const MIXED = chat(
  [
    user(prompt, 4),
    group(
      [
        agent("Retry policy", 3.8, "completed", { ran: 1.2 }),
        agent("Error parsing", 3.8, "completed", { ran: 2 }),
        agent("Timeouts", 3.8, "failed", { ran: 0.6 }),
        agent("Test coverage", 3.8, "running", { action: "bun test src/net", agentId: "a39e817af38ddf5e7" }),
      ],
      3.8,
    ),
  ],
  { isWorking: true },
);

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

/** Opens `name`'s own view from its row in the summary card. */
const openChild = (name: string) => async (ctx: PlayContext) => {
  await openSummary(ctx);
  await ctx.click({ selector: `.acpmux-summary-agent[title="${name}"]` });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of"));
};

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
    "agent-session/acpmux/subagents/SubagentComposer.tsx#SubagentComposer",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
    "agent-session/acpmux/summary/SummaryCard.tsx#SummaryCard",
    "agent-session/acpmux/summary/SummaryBody.tsx#SummaryBody",
    "agent-session/acpmux/summary/SummarySection.tsx#SummarySection",
    "agent-session/acpmux/summary/SubagentStack.tsx#SubagentStack",
    "agent-session/acpmux/summary/SubagentStatusList.tsx#SubagentStatusList",
  ],
  variants: {
    "codex-child": {
      note: "A Codex subagent's own view: its read, as Codex streams it under the child's session.",
      snapshot: CODEX,
      play: openChild("Read a"),
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
    child: {
      note: "A card row opened: the subagent's own view, under a Subagent of pill naming the chat.",
      height: 640,
      snapshot: NESTED_MIXED,
      play: openChild("Test coverage"),
    },
    "child-back": {
      note: "The pill goes back to the parent: the chat's transcript.",
      height: 680,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        await ctx.click({ selector: ".cv-subagent-of__pill" });
        await ctx.waitFor(
          () => !ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".acpmux-thread"),
        );
      },
    },
    "child-close-hover": {
      note: "The pill's × closes the subagent's view; hovered, its highlight covers the × alone, not the pill.",
      height: 640,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of__close"));
        await ctx.hover({ selector: ".cv-subagent-of__close" });
      },
    },
    "child-close": {
      note: "The pill's × goes back to the chat's transcript.",
      height: 680,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        await ctx.click({ role: "button", name: "Close subagent" });
        await ctx.waitFor(
          () => !ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".acpmux-thread"),
        );
      },
    },
    "child-escape": {
      note: "Escape closes the subagent's view, as the × does.",
      height: 680,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        await openChild("Test coverage")(ctx);
        (ctx.document.activeElement as HTMLElement | null)?.blur?.();
        await ctx.press("Escape");
        await ctx.waitFor(
          () => !ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".acpmux-thread"),
        );
      },
    },
    "own-pane": {
      note: 'A pane the app opened on a subagent (a subagent: reveal): its view and a composer of its own, "Message Test coverage", never "Read only"; the line under it names the chat that passes the message on, as a subagent has no session of its own.',
      height: 640,
      snapshot: NESTED_MIXED,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
        page.cmuxAcpmuxBridge?.revealTurn?.(`subagent:${COVERAGE}`);
        await ctx.waitFor(
          () =>
            ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector(".acpmux-subagent-composer"),
        );
        if (ctx.document.querySelector(".acpmux-composer:not(.acpmux-subagent-composer)"))
          throw new Error("a subagent's own pane drew the chat's composer");
        if (ctx.document.body.textContent?.includes("Read only"))
          throw new Error("a subagent's own pane says Read only");
        const field = ctx.document.querySelector(".acpmux-subagent-composer [aria-label]");
        if (field?.getAttribute("aria-label") !== "Message Test coverage")
          throw new Error(`the subagent's composer names ${field?.getAttribute("aria-label")}`);
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
      note: "With a host that opens no pane, a card row shows that subagent in the chat: its own view, its row marked current; nested ones indented. (The app opens it in a pane right of the chat.)",
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
  },
});
