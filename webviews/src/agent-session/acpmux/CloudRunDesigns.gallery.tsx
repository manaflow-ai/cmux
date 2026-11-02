// l10n-allow-file: gallery fixtures (sample folders and machines), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudRunDesignsProps } from "./CloudRunDesigns";

const base = {
  sessions: [],
  peers: ["gpu-box", "Cloud machine"],
  peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" },
  peerConnected: { "gpu-box": true, "Cloud machine": false },
  projectChoices: [{ cwd: "/Users/you/src/atlas-web", label: "atlas-web" }],
  localName: "This Mac",
  environments: true,
  onProject: () => undefined,
  onBrowseProject: () => undefined,
  onConnect: () => undefined,
} satisfies Omit<CloudRunDesignsProps, "design">;

const openList: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
};

export default componentEntry<CloudRunDesignsProps>({
  id: "agent-pane.cloud-run-designs",
  title: "Where a new chat runs: This Mac or Cloud (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/CloudRunDesigns.tsx#CloudRunDesigns"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./CloudRunDesigns").then((module) => module.CloudRunDesigns),
  widths: { narrow: 400, normal: 620 },
  height: 420,
  variants: {
    row: {
      note: "Picked, and the one that ships: Cloud is a row at the top of the picker's Cloud section, with one line on what it does.",
      props: { ...base, design: "row" },
      play: openList,
    },
    bare: {
      note: "The same row with no subtitle: it reads like one more machine.",
      props: { ...base, design: "bare" },
      play: openList,
    },
    chip: {
      note: "A This Mac / Cloud switch beside the picker: two controls for one question.",
      props: { ...base, design: "chip", start: "cloud" },
    },
  },
});
