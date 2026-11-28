// Moment tips (wow idea 20, "show what cmux can do, when it applies"): a built feature's tip shows
// when the person is in its situation, so the tip is about what is in front of them. Each is a
// feature tip (ui/featureTips): the app's `tips.state` claim keeps it once per install, never after
// its control was used, and inside the one 14-day budget every tip and hint shares. What decides the
// moment is the control being on screen: the situation itself, drawn by the pane.
//
// - `moment-plan-compare`: a plan card is waiting (its build menu's chevron, PermissionCard.tsx
//   PlanBuildSplit), the one moment Build on two agents and compare applies.
// - `moment-away-jump`: the person came back to a chat that kept working (the Jump to new pill,
//   SinceDivider.tsx, drawn only on a return with news and the away recap under the line).
import type { TipAnchor } from "../../ui/featureTips/controller";
import type { FeatureTipEntry } from "../../ui/featureTips/policy";

/** The controls a moment tip points at, each drawn only in its situation. */
export const MOMENT_TIP_ANCHORS: Readonly<Record<string, TipAnchor>> = {
  /** The plan card's build menu chevron: a plan waits for its Approve. */
  "agent.planBuild": { selector: ".acpmux-plan-build-split .acpmux-plan-build-chevron", side: "bottom" },
  /** The Jump to new pill, only while shown (it is inert otherwise): a return to news. */
  "agent.sinceJump": { selector: ".acpmux-since-jump[data-shown] .acpmux-since-jump__body", side: "bottom" },
};

type Translate = (key: string) => string;

/** The moment tips, in the pane's language. Ids are install records (Swift AgentPaneFeatureTipRecords):
 *  never rename one, or it shows again. */
export function momentTips(t: Translate): FeatureTipEntry[] {
  return [
    {
      id: "moment-plan-compare",
      anchor: "agent.planBuild",
      title: t("momentTip.planCompare.title"),
      body: t("momentTip.planCompare.body"),
    },
    {
      id: "moment-away-jump",
      anchor: "agent.sinceJump",
      title: t("momentTip.awayJump.title"),
      body: t("momentTip.awayJump.body"),
    },
  ];
}

/** A waiting plan or permission card keeps the turn "working" (App.tsx `turnWorking`), yet the agent
 *  is waiting on the person: that is the moment, not a stream to stay out of. */
export function momentStreaming(turnWorking: boolean, waitingOnPerson: boolean): boolean {
  return turnWorking && !waitingOnPerson;
}
