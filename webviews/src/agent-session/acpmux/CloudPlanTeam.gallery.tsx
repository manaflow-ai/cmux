// l10n-allow-file: gallery fixtures (a sample prompt and team names), not shipped UI.
//
// The pricing card (CloudStartView PlanCard): a Cloud send with no Cloud plan, the platform's refusal or the page's
// own hold when `cloudMachine.list` says `plan.state` `none`, shows Pro and Max with Subscribe each. In a team that
// is not the person's own it says "This team has no Cloud plan" and offers the person's own team first. Leo,
// 2026-11-09: "i guess is team? it's kinda hard to realize tho". The looks compare where the words go; the pane
// draws `notice`. A folder that needs a larger machine than the plan includes (`cloud_size_locked`) offers the plan
// that does.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";
import { createCloudPlanSubscribe } from "./cloudPlanSubscribe";

const noPlan: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
  code: "cloud_plan_required",
  refusedHere: true,
};
const sizeLocked: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
  code: "cloud_size_locked",
  retryable: true,
  message: "This folder needs a machine with 16 vCPU and 32 GB memory, more than your plan includes.",
  sizeLocked: { needed: "xl", allowed: "lg", upgradePlan: "max" },
};
const refused: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
  code: "cloud_plan_required",
  message: "Cloud machines need a Pro plan.",
  planTeam: { team: "cmux", switchTo: { id: "team_0123456789abcdef0123", name: "Personal" } },
};
// Subscribe's fixture host: it opens the checkout, and the page never becomes the key one again here.
const planStore = createCloudPlanSubscribe({
  call: async () => ({ opened: true }),
  watchKey: () => () => undefined,
  isKey: () => false,
});
const actions = {
  onSwitchTeam: () => undefined,
  planStore,
  onRunHere: () => undefined,
  onDismiss: () => undefined,
};

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-plan-team",
  title: "Cloud start: plans and this team has no Cloud plan",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/CloudStartView.tsx",
    "agent-session/acpmux/cloudPlanTeams.ts",
    "agent-session/acpmux/cloudPlans.ts",
    "agent-session/acpmux/cloudPlanSubscribe.ts",
  ],
  keywords: ["cloud", "plan", "pricing", "subscribe", "pro", "max", "size", "team", "switch", "upgrade", "refusal"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 260,
  variants: {
    pricing: {
      note: "No Cloud plan (the page's hold at Send, or the platform's refusal): Cloud needs a plan, Pro and Max side by side with their price, the largest machine each includes and Subscribe (Pro filled), then Run on This Mac and Not now.",
      props: { start: noPlan, ...actions },
      height: 340,
    },
    "size-locked": {
      note: "The folder needs a larger machine than the plan includes: the size in vCPU and memory, Upgrade to Max (filled), Run on This Mac and Retry.",
      props: { start: sizeLocked, ...actions, onRetry: () => undefined },
    },
    "size-locked-largest": {
      note: "On the largest plan already: the folder is too large for Cloud, Run on This Mac (filled) and Retry, no upgrade.",
      props: {
        start: {
          ...sizeLocked,
          message: "This folder is too large for Cloud. It needs 16 vCPU and 32 GB memory.",
          sizeLocked: { needed: "xl", allowed: "lg", upgradePlan: null },
        },
        ...actions,
        onRetry: () => undefined,
      },
    },
    notice: {
      note: "Under the message, no startup card (nothing started): the title, the team picked in the team menu, then the plans, Switch to the person's own team first (filled), Run on This Mac and Not now.",
      props: { start: refused, ...actions },
    },
    card: {
      note: "The failed startup card stays above the same words and buttons: the checklist adds a failed machine row that explains nothing more.",
      props: { start: { ...refused, step: "machine" }, ...actions, planTeamLook: "card" },
      // The failed checklist opens on its own: the stage leaves room for it, the team line and the buttons.
      height: 560,
    },
    banner: {
      note: "The title and the buttons on one line, the team under them: tight, but the buttons wrap under the title at narrow widths.",
      props: { start: refused, ...actions, planTeamLook: "banner" },
    },
    "no-own-team": {
      note: "The team menu lists no personal team (or the device is kept to one team): Pro's Subscribe leads; the team is still named.",
      props: { start: { ...refused, planTeam: { team: "cmux" } }, ...actions },
    },
    "long-names": {
      note: "Long team names wrap inside their buttons' row without pushing the title.",
      height: 320,
      props: {
        start: {
          ...refused,
          planTeam: {
            team: "Manaflow Research and Platform Engineering",
            switchTo: { id: "team_0123456789abcdef0123", name: "Personal account of leo@cmux.com" },
          },
        },
        ...actions,
      },
    },
  },
});
