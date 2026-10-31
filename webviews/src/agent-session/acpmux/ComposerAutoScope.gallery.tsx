// l10n-allow-file: gallery fixtures (sample folders and machines), not shipped UI.
//
// The New Tab scope line under Auto (ComposerContext `auto`, autoEnvironment.ts): where the new chat
// runs when nobody picked. The folder's run location by default (Cloud when its newest chat went to
// Cloud), moved only by a prompt that asks for a destination. Compare arms shows the three
// `auto-scope-look` faces; Cloud picked by hand is the before.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { autoScopeLook } from "./autoScope.experiment";
import { ComposerContext } from "./ComposerContext";

const base = {
  sessions: [],
  peers: ["gpu-box", "Cloud machine"],
  peerKinds: { "gpu-box": "ssh", "Cloud machine": "cloud" } as const,
  peerConnected: { "gpu-box": true, "Cloud machine": true },
  projectChoices: [{ cwd: "/Users/you/src/atlas-web", label: "atlas-web" }],
  summary: { sessionId: "", cwd: "/Users/you/src/atlas-web" },
  localName: "This Mac",
  environments: true,
  onProject: () => undefined,
  onConnect: () => undefined,
} satisfies Partial<ComponentProps<typeof ComposerContext>>;
const persistent = { mode: "persistent", onMode: () => undefined, onDefault: () => undefined } as const;
const cloud = { ...persistent, mode: "cloud" } as const;
const auto = (detail: string, kind: "local" | "cloud" | "ssh") => ({
  detail,
  kind,
  selected: true,
  onPick: () => undefined,
});

const openPicker: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [role="option"]'));
};

export default componentEntry<ComponentProps<typeof ComposerContext>>({
  id: "agent-pane.composer-auto-scope",
  title: "Auto scope line",
  area: "New Tab",
  experimental: true,
  pane: true,
  covers: [
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/EnvironmentPicker.tsx#AutoIcon",
  ],
  keywords: ["auto", "cloud", "environment", "run location", "folder"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: () => import("./ComposerContext").then((module) => module.ComposerContext),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 180,
  variants: {
    "folder-local": {
      note: "Auto, the folder's newest chat ran on this Mac (or the folder has none): this Mac.",
      props: { ...base, runMode: persistent, auto: auto("This Mac", "local") },
    },
    "folder-cloud": {
      note: "Auto, the folder's newest chat went to Cloud: Cloud, for every prompt that names no destination.",
      props: { ...base, runMode: cloud, auto: auto("Cloud", "cloud") },
    },
    "prompt-machine": {
      note: "Auto, the prompt says “run the tests on gpu-box”: that machine, while the prompt says so.",
      props: { ...base, runMode: persistent, auto: auto("gpu-box", "ssh") },
    },
    "picker-open": {
      note: "The picker under Auto with a Cloud folder: Auto checked at the top, Cloud and every machine one click below.",
      height: 640,
      props: { ...base, runMode: cloud, auto: auto("Cloud", "cloud") },
      play: openPicker,
    },
    "cloud-picked": {
      note: "Before: Cloud picked by hand (no Auto). The face reads Cloud and the Cloud row is checked.",
      props: { ...base, runMode: cloud },
    },
  },
  experiment: { definition: autoScopeLook, script: [{ name: "Open the picker", run: openPicker }] },
});
