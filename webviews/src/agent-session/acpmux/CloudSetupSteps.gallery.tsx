// l10n-allow-file: gallery fixtures (a sample prompt and model ids), not shipped UI.
//
// A new person's first Cloud send (conversation/CloudSetupSteps.tsx): the gates it meets after Send, in order
// (sign in, a plan, a model connection), each card with the setup strip on top so it reads as a step on the way
// and says what is left. Three looks of the strip side by side: `rail` (shipped, every step in one row), `count`
// (one caption) and `list` (a row per step); each at the sign-in, plan and model steps.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";
import type { CloudSetupStepsLook } from "./conversation/cloudSetupStep";

const base: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "failed",
  folder: "paint",
};
const signedOut: CloudStartProgress = { ...base, code: "not_signed_in", message: "Sign in to continue" };
const signingIn: CloudStartProgress = { ...base, state: "starting", signingIn: true };
const noPlan: CloudStartProgress = { ...base, code: "cloud_plan_required", refusedHere: true };
const noModel: CloudStartProgress = {
  ...base,
  code: "cloud_setup_required",
  message: "cloud_setup_required",
  cloudSetup: { family: "claude", model: "claude-opus-5-5" },
};
const handlers = {
  onSignIn: async () => undefined,
  onRunHere: () => undefined,
  onDismiss: () => undefined,
  onSetUp: () => undefined,
  onSetUpDismiss: () => undefined,
};
const at = (look: CloudSetupStepsLook, start: CloudStartProgress) => ({
  start,
  setupStepsLook: look,
  ...handlers,
});

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-setup-steps",
  title: "Cloud start: first-send setup steps",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/CloudSetupSteps.tsx",
    "agent-session/acpmux/conversation/CloudSetupCard.tsx",
    "agent-session/acpmux/CloudStartView.tsx",
  ],
  keywords: ["cloud", "onboarding", "first run", "sign in", "plan", "model", "setup", "steps"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 300,
  variants: {
    "rail-sign-in": {
      note: "Shipped look. Signed out: step 1 of 3 named in a row with the plan and model after it; Sign in, Run on This Mac and Not now. The message is kept.",
      props: at("rail", signedOut),
    },
    "rail-signing-in": {
      note: "The browser is out: the same card waits with Sign in at rest, so the person keeps their place.",
      props: at("rail", signingIn),
    },
    "rail-sign-in-no-handler": {
      note: "A signed-out card waiting for its sign-in handler stays calm and never falls back to a failed startup checklist.",
      props: { start: signedOut, setupStepsLook: "rail", onRunHere: handlers.onRunHere, onDismiss: handlers.onDismiss },
    },
    "rail-plan": {
      note: "Signed in, no plan: sign in is checked, the plan is current, and the pricing card reads as a step, not an alert.",
      height: 380,
      props: at("rail", noPlan),
    },
    "rail-model": {
      note: "Signed in with a plan, nothing serves the model: the last step, Set up Cloud's ways in.",
      props: at("rail", noModel),
    },
    "count-sign-in": {
      note: "Count look: one caption line, Step 1 of 3 · Sign in. Quietest, but the later steps are not named.",
      props: at("count", signedOut),
    },
    "count-plan": { note: "Count look at the plan step.", height: 380, props: at("count", noPlan) },
    "count-model": { note: "Count look at the model step.", props: at("count", noModel) },
    "list-sign-in": {
      note: "List look: one row per step. Names every step but takes three rows above the card's own title.",
      height: 340,
      props: at("list", signedOut),
    },
    "list-plan": { note: "List look at the plan step.", height: 420, props: at("list", noPlan) },
    "list-model": { note: "List look at the model step.", height: 340, props: at("list", noModel) },
  },
});
