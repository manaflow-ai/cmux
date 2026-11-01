// l10n-allow-file: gallery fixtures (a sample prompt, machine names and host words), not shipped UI.
//
// A chat starting in Cloud (CloudStartView.tsx): the person's message, then the start as metadata
// under it (step, folder, machine, secrets, network), never a modal. Compare arms shows the three
// layouts of the `cloud-start-look` experiment.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { cloudStartLook } from "./cloudStart.experiment";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

const begun: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "starting",
  folder: "paint",
};
const known = { machine: "paint-dev", size: "4 CPU · 16 GB", secrets: 3, network: "limited" } as const;

const showStart: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-start__status"));
};

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-start",
  title: "Cloud start progress",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/CloudStartView.tsx"],
  keywords: ["cloud", "machine", "start", "progress", "secrets", "network"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 300,
  variants: {
    sent: {
      note: "Just sent, before the host says anything: the message, a spinner, and the folder it copies.",
      props: { start: begun },
    },
    machine: {
      note: "The host is getting a machine: the step and the machine with its size.",
      props: { start: { ...begun, step: "machine", machine: known.machine, size: known.size } },
    },
    copying: {
      note: "The folder is copying: every fact known (folder, machine, secrets, a limited network).",
      props: { start: { ...begun, step: "folder", ...known } },
    },
    opening: {
      note: "Last step: the chat opens on the machine, then this tab closes.",
      props: { start: { ...begun, step: "opening", ...known, network: "full" } },
    },
    failed: {
      note: "The start failed: the host's words where the spinner was; the message stays in the composer.",
      props: {
        start: {
          ...begun,
          step: "folder",
          ...known,
          state: "failed",
          message: "Couldn't copy paint to paint-dev: the machine stopped answering.",
        },
      },
    },
  },
  // The gallery loads no experiment without a step (format.ts validateEntries): the card is static,
  // so its one step waits for the card the arm draws.
  experiment: { definition: cloudStartLook, script: [{ name: "Show the start", run: showStart }] },
});
