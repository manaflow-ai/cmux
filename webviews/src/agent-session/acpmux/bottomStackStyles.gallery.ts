// l10n-allow-file: gallery fixtures (prompts, subagent names, pull request titles), not shipped UI.
// The chat's whole bottom stack at once (bottomStack.css): the chat's pull requests, the running
// tray (collapsed to its "Running in background · …" header, or open) and the composer, with
// synthetic data: several subagents in the background, one chat waiting on you, two PRs.
// test/agent-pane-bottom-stack-edges.test.ts measures every card's left and right edge and the
// gaps between them here.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { activity, assistant, chat, row, session, SESSION_ID, tool, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import type { PlayContext } from "../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

const NAMES = [
  "Audit the picker",
  "Check the docs",
  "Read the updater",
  "Find the release script",
  "Trace the resize lag",
  "Review the tray diff",
  "Measure the composer",
  "Search the changelog",
  "Compare the gallery",
];
const ACTIONS = [
  "Read QuickModelMenu.tsx",
  "Read docs/updates.md",
  "Read Sources/Updater.swift",
  "Search scripts/release",
  "Read ResizeObserver.ts",
  "Read subagents.css",
  "Read composerLocation.css",
  "Search CHANGELOG.md",
  "Read gallery/format.ts",
];
const agents: Subagent[] = NAMES.map((name, index) => ({
  id: `stack-agent-${index + 1}`,
  parent: null,
  name,
  task: name,
  kind: index % 2 ? "general-purpose" : "Explore",
  state: "running",
  background: true,
  startedAt: minutesAgo(12 - index),
  action: ACTIONS[index],
}));
const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });

/** The stack's data: `working` is whether the turn still runs (its tray header then counts what
 *  runs; after it, "Running in background · …"); `prs` whether the chat opened its two pull
 *  requests; `tray` whether subagents run in the background. */
function stack(working: boolean, { prs = true, tray = true }: { prs?: boolean; tray?: boolean } = {}) {
  const base = chat(
    [
      user("Fan out on the picker and the composer, and open the two PRs", 14),
      ...(prs
        ? [activity([create("fix(picker): keep the model list in view", 128), create("Composer: one edge", 129)], 13)]
        : []),
      ...(tray ? [row(SUBAGENTS, 12, { subagents: agents })] : []),
      assistant(
        tray
          ? "Both PRs are open. Nine subagents are still checking in the background."
          : "Both PRs are open and the checks are done.",
        2,
      ),
    ],
    { isWorking: working },
  );
  return tray
    ? {
        ...base,
        sessions: [
          ...base.sessions,
          session({
            sessionId: "stack-child-waiting",
            title: "Review the resize fix",
            spawnedBy: SESSION_ID,
            indicator: "input",
            status: "waiting",
            createdAt: minutesAgo(6),
          }),
        ],
      }
    : base;
}

async function settled(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
  // Motion that ends (an entrance, a fold) has ended; a running line's spinner turns for as long as
  // the line runs, so it is not waited for.
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-dock *")].every((node) =>
      node
        .getAnimations()
        .every(
          (animation) =>
            animation.playState !== "running" ||
            !Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)),
        ),
    ),
  );
}
const collapsed = settled;
async function expanded(ctx: PlayContext) {
  await settled(ctx);
  const head = ctx.document.querySelector(".acpmux-running-tray__head");
  if (head && head.getAttribute("aria-expanded") !== "true")
    await ctx.click({ selector: ".acpmux-running-tray__head" });
  await settled(ctx);
}
async function prsOpen(ctx: PlayContext) {
  await settled(ctx);
  const count = ctx.document.querySelector(".acpmux-pr-count");
  if (count && count.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-pr-count" });
  await settled(ctx);
  // One row hovered: its highlight, and no control of its own (its menu dismisses it).
  await ctx.hover({ selector: ".acpmux-pr-stack__chip:first-child .acpmux-pr-stack__link" });
}

const variant = (
  note: string,
  working: boolean,
  fields: Partial<AgentPaneVariant> & { prs?: boolean; tray?: boolean } = {},
): AgentPaneVariant => {
  const { prs, tray, ...rest } = fields;
  return {
    note,
    snapshot: stack(working, { ...(prs === undefined ? {} : { prs }), ...(tray === undefined ? {} : { tray }) }),
    play: working ? expanded : collapsed,
    ...rest,
  };
};
const inTray = { documentAttributes: { "pr-control": "tray" } };
const above = { documentAttributes: { "pr-control": "above" } };

export default agentPaneEntry({
  id: "agent-pane.bottom-stack-styles",
  title: "Bottom stack: pull requests, running tray and composer",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/summary/PullRequestStack.tsx"],
  variants: {
    collapsed: variant(
      "Selected (count in the quiet row): the turn ended, the tray folded to its Running in background header; \"2 PRs\" sits beside the mode in the composer's quiet row and adds no row. The tray and the composer are one glass stack on the card's two edges.",
      false,
    ),
    "no-tray": variant(
      "Selected, no subagents: the count stays in the quiet row; nothing stands over the composer.",
      false,
      {
        tray: false,
      },
    ),
    expanded: variant("Selected, the turn running: the tray open, a line each.", true),
    "prs-open": variant(
      "Selected, the count opened: a chip per pull request at the card's full width, right over the composer; the hovered row lights, with no control of its own (a right-click dismisses it).",
      false,
      { play: prsOpen },
    ),
    "no-prs": variant("No pull requests: the same stack, for the height the count must not add.", false, {
      prs: false,
    }),
    "no-tray-no-prs": variant("No pull requests and no tray: the composer alone.", false, { prs: false, tray: false }),
    "in-tray": variant(
      "Alternative (on the tray's header line): the count trails on the Running in background line, before its time; with no tray it falls back to the quiet row.",
      false,
      inTray,
    ),
    "in-tray-no-tray": variant("Alternative (on the tray's header line), no tray: the quiet row.", false, {
      ...inTray,
      tray: false,
    }),
    above: variant(
      "Alternative (over the composer's left edge): a bare count with no row background over the card; it adds its own line.",
      false,
      above,
    ),
    "above-no-tray": variant("Alternative (over the composer's left edge), no tray.", false, { ...above, tray: false }),
    cards: variant(
      "Alternative stack look (separate cards): the tray and the opened chips keep their own rounded cards on the composer's two edges, one 4px step apart.",
      false,
      { documentAttributes: { "bottom-stack": "cards" } },
    ),
    "legacy-bars": variant(
      "Before cmux#26082 (comparison): the pull request bars stacked over the composer, each its own width.",
      false,
      { documentAttributes: { "pr-dock": "full" } },
    ),
  },
});
