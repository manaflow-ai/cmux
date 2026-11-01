// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// The chat's whole bottom stack at once (bottomStack.css): the running tray (collapsed to its
// "Running in background · …" header, or open) and the composer, with synthetic data: several
// subagents in the background and one chat waiting on you.
// test/agent-pane-bottom-stack-edges.test.ts measures every card's left and right edge and the
// gaps between them here.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, row, session, SESSION_ID, user } from "../../gallery/fixtures/acpmux";
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
/** The stack's data: `working` is whether the turn still runs (its tray header then counts what
 *  runs; after it, "Running in background · …"); `tray` whether subagents run in the background. */
function stack(working: boolean, { tray = true }: { tray?: boolean } = {}) {
  const base = chat(
    [
      user("Fan out on the picker and the composer", 14),
      ...(tray ? [row(SUBAGENTS, 12, { subagents: agents })] : []),
      assistant(tray ? "Nine subagents are still checking in the background." : "The checks are done.", 2),
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

const variant = (
  note: string,
  working: boolean,
  fields: Partial<AgentPaneVariant> & { tray?: boolean } = {},
): AgentPaneVariant => {
  const { tray, ...rest } = fields;
  return {
    note,
    snapshot: stack(working, tray === undefined ? {} : { tray }),
    play: working ? expanded : collapsed,
    ...rest,
  };
};

export default agentPaneEntry({
  id: "agent-pane.bottom-stack-styles",
  title: "Bottom stack: running tray and composer",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/bottomStack.css"],
  variants: {
    collapsed: variant(
      "Selected: the turn ended, the tray folded to its Running in background header. The tray and the composer are one glass stack on the card's two edges.",
      false,
    ),
    "no-tray": variant("Selected, no subagents: nothing stands over the composer.", false, { tray: false }),
    expanded: variant("Selected, the turn running: the tray open, a line each.", true),
    cards: variant(
      "Alternative stack look (separate cards): the tray keeps its own rounded card on the composer's two edges, one 4px step apart.",
      false,
      { documentAttributes: { "bottom-stack": "cards" } },
    ),
  },
});
