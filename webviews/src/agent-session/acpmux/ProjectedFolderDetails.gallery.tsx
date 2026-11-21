// l10n-allow-file: gallery fixtures are developer examples, not shipped copy.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";
import { projectedFolderDetails } from "./projectedFolderDetails.experiment";

const start: CloudStartProgress = {
  key: "projection-details",
  task: "Inspect the attached folder.",
  state: "starting",
  step: "opening",
  folder: "demo-project",
  agent: "Codex",
  clone: { state: "done", phase: "complete", projection: { files: 1100000, bytes: 114890375168, mountMs: 940 } },
};
export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.projected-folder-details",
  title: "Projected folder details",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/cloudStartViewModel.ts"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 380,
  variants: {
    projected: { note: "Synthetic manifest receipt; compare off and on, not a new benchmark.", props: { start } },
    empty: {
      note: "An empty projected folder is a valid receipt.",
      props: {
        start: {
          ...start,
          clone: { state: "done", phase: "complete", projection: { files: 0, bytes: 0, mountMs: 0 } },
        },
      },
    },
    fallback: {
      note: "No projection receipt: copy fallback stays unchanged in both arms.",
      props: { start: { ...start, clone: { state: "done", phase: "complete", fallback: "not_git" } } },
    },
  },
  experiment: {
    definition: projectedFolderDetails,
    script: [
      {
        name: "Open startup details",
        run: async (ctx) => {
          await ctx.click({ selector: ".acpmux-cloud-start__summary" });
          await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-start__checklist"));
        },
      },
    ],
  },
});
