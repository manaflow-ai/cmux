// l10n-allow-file: gallery fixtures (a sample machine name and failure), not shipped UI.
// The Cloud progress page (cmux-page://cmux.cloud-progress/): a window waiting on its Cloud machine,
// at each stage. Compare arms shows the `cloud-progress-look` layouts (line, steps, card) side by side.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import { cloudProgressLook } from "./cloudProgress.experiment";
import table from "./generated/strings.json";
import { CloudProgressView } from "./CloudProgressPage";
import { SAMPLE_ASKS, sampleState } from "./mockProvider";
import type { CloudProgressState } from "./types";

type Props = { state: CloudProgressState };

function CloudProgressGallery({ state }: Props) {
  const [strings] = useState(() => createStrings(table));
  return (
    <CloudProgressView
      snapshot={{ state, receivedAt: Date.now() }}
      strings={strings}
      onAction={() => {}}
      onAnswer={() => {}}
    />
  );
}

const showProgress: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cloud-progress__title"));
};

const TRIGGER = ".cloud-progress__disclosure .ui-disclosure-trigger";
const PANEL = ".cloud-progress__disclosure .ui-disclosure-panel";
const settled = (ctx: Parameters<Play>[0]) => ctx.document.getAnimations().length === 0;

/// Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key".
/// The status line opens the steps under it on the settle; they end on their final layout, nothing running.
const stepsOpen: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TRIGGER));
  await ctx.click({ selector: TRIGGER });
  await ctx.waitFor(() => ctx.document.querySelector(PANEL) && settled(ctx), { capMs: 3000 });
};

/// The failed page's steps (open) fold away into the status line, and are gone when the motion ends.
const stepsClose: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(PANEL));
  await ctx.click({ selector: TRIGGER });
  await ctx.waitFor(() => !ctx.document.querySelector(PANEL) && settled(ctx), { capMs: 3000 });
};

/// The steps opening, every motion held 60 ms in: most of the way, decelerating into the end.
const stepsMid: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TRIGGER));
  await ctx.click({ selector: TRIGGER });
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

export default componentEntry<Props>({
  id: "pages.cloud-progress",
  title: "Cloud machine progress",
  area: "Pages",
  experimental: true,
  height: 560,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["page:cmux.cloud-progress", "pages/cloud-progress/CloudProgressPage.tsx"],
  keywords: ["cloud", "machine", "new cloud workspace", "progress", "paused", "resume", "retry"],
  load: async () => CloudProgressGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("./styles.css");
  },
  variants: {
    requesting: {
      note: "Just clicked New Cloud Workspace: the request is on its way, no machine name yet.",
      props: { state: sampleState("requesting") },
    },
    creating: {
      note: "cmux Cloud is creating the VM.",
      props: { state: sampleState("creating") },
    },
    booting: {
      note: "The VM exists and has its name; this Mac waits for its cmux-tui to answer.",
      props: { state: sampleState("booting") },
    },
    connecting: {
      note: "The link is up; the machine's workspaces load.",
      props: { state: sampleState("connecting") },
    },
    failed: {
      note: "The link closed at Starting the machine: the reason, Retry, Copy Error and Dismiss, in the room they kept.",
      props: { state: sampleState("failed", { step: 2 }) },
    },
    paused: {
      note: "A window on a paused machine's workspace: Paused, not a failure; Resume is one click.",
      props: { state: sampleState("paused", { step: 3 }) },
    },
    "paused-idle": {
      note: "Paused by the idle auto-pause: its own words, the same Resume.",
      props: { state: sampleState("paused", { step: 3, idle: true }) },
    },
    "ask-agent-request": {
      note: "An agent asked for the machine: Create or Cancel on the page, where the sheet used to ask.",
      props: { state: sampleState("requesting", { ask: SAMPLE_ASKS.createRequest }) },
    },
    "ask-approval": {
      note: "cmux Cloud holds the create for the person's approval: the same question in the same place.",
      props: { state: sampleState("creating", { ask: SAMPLE_ASKS.approval }) },
    },
    "ask-upgrade": {
      note: "The plan refused the machine: Upgrade or Cancel on the failed page, no second sheet.",
      props: {
        state: sampleState("failed", {
          step: 1,
          failure: "Your plan allows no more running machines.",
          ask: SAMPLE_ASKS.upgrade,
        }),
      },
    },
    "steps-fold-open": {
      note: "Chosen. The status line opens the steps under it as one motion on the settle (--cmux-ease-settle over --cmux-motion-settle): their height and opacity together, the blocks under them moving on the same frames.",
      props: { state: sampleState("booting") },
      play: stepsOpen,
    },
    "steps-fold-mid": {
      note: "The same fold held 60 ms in: fast at first, decelerating into its end, never past it.",
      props: { state: sampleState("booting") },
      play: stepsMid,
    },
    "steps-fold-close": {
      note: "The failed page's steps fold away into the status line; nothing is left drawn when the motion ends.",
      props: { state: sampleState("failed", { step: 2 }) },
      play: stepsClose,
    },
    resuming: {
      note: "Resume pressed: cmux Cloud is starting the machine again.",
      props: { state: sampleState("resuming", { step: 3, finished: false }) },
    },
  },
  experiment: { definition: cloudProgressLook, script: [{ name: "Show the progress", run: showProgress }] },
});
