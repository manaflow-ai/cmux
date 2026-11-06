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
import { sampleState } from "./mockProvider";
import type { CloudProgressState } from "./types";

type Props = { state: CloudProgressState };

function CloudProgressGallery({ state }: Props) {
  const [strings] = useState(() => createStrings(table));
  return <CloudProgressView snapshot={{ state, receivedAt: Date.now() }} strings={strings} onAction={() => {}} />;
}

const showProgress: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cloud-progress__title"));
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
    resuming: {
      note: "Resume pressed: cmux Cloud is starting the machine again.",
      props: { state: sampleState("resuming", { step: 3, finished: false }) },
    },
  },
  experiment: { definition: cloudProgressLook, script: [{ name: "Show the progress", run: showProgress }] },
});
