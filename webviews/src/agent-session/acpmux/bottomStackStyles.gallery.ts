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
 *  runs; after it, "Running in background · …"). */
function stack(working: boolean) {
  const base = chat(
    [
      user("Fan out on the picker and the composer, and open the two PRs", 14),
      activity([create("fix(picker): keep the model list in view", 128), create("Composer: one edge", 129)], 13),
      row(SUBAGENTS, 12, { subagents: agents }),
      assistant("Both PRs are open. Nine subagents are still checking in the background.", 2),
    ],
    { isWorking: working },
  );
  return {
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
  };
}

async function settled(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-dock .acpmux-running-tray"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-dock *")].every((node) =>
      node.getAnimations().every((animation) => animation.playState !== "running"),
    ),
  );
}
const collapsed = settled;
async function expanded(ctx: PlayContext) {
  await settled(ctx);
  const head = ctx.document.querySelector(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await settled(ctx);
}

async function prsOpen(ctx: PlayContext) {
  await settled(ctx);
  const row = ctx.document.querySelector(".acpmux-pr-stack__row");
  if (row && row.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-pr-stack__row" });
  await settled(ctx);
}

const variant = (note: string, working: boolean, fields: Partial<AgentPaneVariant> = {}): AgentPaneVariant => ({
  note,
  snapshot: stack(working),
  play: working ? expanded : collapsed,
  ...fields,
});

export default agentPaneEntry({
  id: "agent-pane.bottom-stack-styles",
  title: "Bottom stack: pull requests, running tray and composer",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/bottomStack.css", "agent-session/acpmux/summary/PullRequestStack.tsx"],
  variants: {
    collapsed: variant(
      "Selected (one glass stack): the turn ended, the tray folded to its Running in background header; the N PRs row, the tray and the composer share one rim and two edges, with no gap and no notch.",
      false,
    ),
    expanded: variant("Selected, the turn running: the tray open, a line each.", true),
    "prs-open": variant("Selected, the N PRs row opened: a chip per pull request at the card's full width.", false, {
      play: prsOpen,
    }),
    cards: variant(
      "Alternative (separate cards): every part keeps its own rounded card on the composer's two edges, one 4px step apart.",
      false,
      { documentAttributes: { "bottom-stack": "cards" } },
    ),
    strip: variant(
      "Alternative (compact strip): the one glass stack, with the pull requests' links on their count's own line.",
      false,
      { documentAttributes: { "bottom-stack": "strip" } },
    ),
    "legacy-bars": variant(
      "Before cmux#26082 (comparison): the pull request bars stacked over the composer, each its own width.",
      false,
      { documentAttributes: { "pr-dock": "full" } },
    ),
  },
});
