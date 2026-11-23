// l10n-allow-file: gallery fixtures (plans, prompts), not shipped UI.
// The plan the person approved stays in sight while the agent builds it (ApprovedPlanBand.tsx). Leo's
// feature-map row: "plan pane that stays during the build, editable plan sent back". acpmux keeps the
// approved plan on the session (summary `approvedPlan`); the band shows it until the person closes it
// or a new plan is approved. The experiment compares how it stays (approvedPlan.experiment.ts; view
// Compare arms).
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import type { ApprovedPlan } from "./approvedPlan";
import { approvedPlanPlace } from "./approvedPlan.experiment";

const PLAN = [
  "## Retry uploads",
  "",
  "1. Add `withRetry` around the upload call, three tries with backoff.",
  "2. Surface the last error in the toast instead of a generic failure.",
  "3. Cover the retry and the give-up path in `upload.test.ts`.",
].join("\n");

const plan = (edited = false): ApprovedPlan => ({
  markdown: edited ? `${PLAN}\n4. Skip retries for 4xx answers.` : PLAN,
  edited,
  permissionId: edited ? "perm-edited" : "perm-plan",
});

function buildingChat(approved: ApprovedPlan): AcpmuxSnapshot {
  const snapshot = chat(
    [user("Plan the upload retries first", 12), assistant("Approved. Adding withRetry to the upload call now.", 2)],
    { harness: "claude", isWorking: true },
  );
  return { ...snapshot, summary: { ...snapshot.summary!, harness: "claude", approvedPlan: approved } };
}

const toggle = { selector: ".acpmux-approved-plan-toggle" };
const opened = (ctx: PlayContext) =>
  ctx.document.querySelector(".acpmux-approved-plan")?.hasAttribute("data-open") === true;
const open = async (ctx: PlayContext) => {
  await ctx.click(toggle);
  await ctx.waitFor(() => opened(ctx));
};

export default agentPaneEntry({
  id: "agent-pane.approved-plan",
  title: "Composer hat: the approved plan during the build",
  area: "Agent pane",
  height: 460,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/ApprovedPlanBand.tsx#ApprovedPlanBand",
    "agent-session/acpmux/ApprovedPlanBand.css",
    "agent-session/acpmux/approvedPlan.experiment.ts",
  ],
  experiment: {
    definition: approvedPlanPlace,
    script: [
      { name: "a click opens the plan in place", run: open },
      {
        name: "a second click folds it",
        run: async (ctx: PlayContext) => {
          await ctx.click(toggle);
          await ctx.waitFor(() => !opened(ctx));
        },
      },
    ],
  },
  variants: {
    folded: {
      note: "Shipped: \"plan pane that stays during the build\". One line in the hat's glass while the agent works: Approved plan, the plan's title, a chevron and ×.",
      snapshot: buildingChat(plan()),
    },
    open: {
      note: "Opened in place: the plan's Markdown in a bounded body that scrolls, the composer stays where it was.",
      snapshot: buildingChat(plan()),
      play: open,
    },
    edited: {
      note: 'The person edited the plan before approving it ("editable plan sent back"): an Edited tag, and the band shows their text.',
      snapshot: buildingChat(plan(true)),
      play: open,
    },
  },
});
