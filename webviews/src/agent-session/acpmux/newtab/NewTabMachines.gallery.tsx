// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
//
// The New Tab machines widget as buttons (AmbientWidgets.tsx; Leo, 2026-10-26: "in the new tab
// page ... we should have buttons for connected cloud machines? and adding new stuff ... the
// buttons should at least be displaying well and able to send you to the nicest easiest places"):
// each machine with its live link, a press that starts the next chat there, and Add Machine….
// Compare arms shows the three looks of the `new-tab-machines-look` experiment.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { CloudMachine } from "../cloudMachines";
import { AmbientWidgets } from "./AmbientWidgets";
import { newTabMachinesLook } from "./machinesLook.experiment";

type Props = ComponentProps<typeof AmbientWidgets>;

const buttons = {
  current: "local",
  onPick: () => undefined,
  onReconnect: () => undefined,
  onCloudMachine: () => undefined,
  onAddMachine: () => undefined,
};

// Three SSH machines acpmux lists, one per link state, and an account Cloud machine it does not
// list, paused.
const fleet: Props["snapshot"] = {
  sessions: [],
  peers: ["build-box", "gpu-box", "lab-mini"],
  peerKinds: { "build-box": "ssh", "gpu-box": "ssh", "lab-mini": "ssh" },
  peerConnected: { "build-box": true, "gpu-box": false, "lab-mini": false },
  peerStates: { "build-box": "connected", "gpu-box": "reconnecting", "lab-mini": "offline" },
};
const paused: CloudMachine[] = [{ id: "m-1", name: "atlas-web", stage: "paused" }];

const base: Props = {
  machines: true,
  snapshot: fleet,
  localName: "This Mac",
  now: 0,
  buttons,
  cloudMachines: paused,
};

const showMachines: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-machines .nt-machine-add"));
};

export default componentEntry<Props>({
  id: "agent-pane.new-tab-machines",
  title: "New Tab machines",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/newtab/AmbientWidgets.tsx"],
  keywords: ["new tab", "machines", "remote", "ssh", "cloud", "add machine", "reconnect"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../composerLocation.css"), import("./screen.css")]),
  load: () => import("./AmbientWidgets").then((module) => module.AmbientWidgets),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 160,
  variants: {
    fleet: {
      note: "This Mac (picked), build-box connected (green), gpu-box reconnecting (the spinner), lab-mini offline (red: a press reconnects it and picks it), atlas-web a paused Cloud machine (grey: a press resumes it), then Add Machine….",
      props: base,
    },
    "picked-remote": {
      note: "The next chat goes to build-box: its button reads pressed.",
      props: { ...base, buttons: { ...buttons, current: "build-box" } },
    },
    "this-mac-only": {
      note: "No other machine yet: This Mac and Add Machine…, which opens Add Device.",
      props: { ...base, snapshot: { sessions: [], peers: [] }, cloudMachines: [] },
    },
  },
  experiment: { definition: newTabMachinesLook, script: [{ name: "Show the machines", run: showMachines }] },
});
