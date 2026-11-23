// l10n-allow-file: gallery fixtures for the AUTO computer chip (cmuxterm-hq RFD 0078), not shipped UI.
// Leo, 2026-11-23: "if you pick our fucking auto mode, which is our default mode, right? And we want
// to make that default glaringly obvious". One chip says where an agent runs, how big its computer
// is and why; it opens to pin any of them. The new-agent card asks for a task and a project only.
import { componentEntry } from "../../gallery/format";
import type { AutoComputerDesignsProps } from "./AutoComputerDesigns";

export default componentEntry<AutoComputerDesignsProps>({
  id: "agent-pane.auto-computer-designs",
  title: "AUTO computer chip: where, how big, why (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/AutoComputerDesigns.tsx#AutoComputerDesigns"],
  styles: () => Promise.all([import("./styles.css"), import("./composerStates.css")]),
  load: () => import("./AutoComputerDesigns").then((module) => module.AutoComputerDesigns),
  widths: { narrow: 400, normal: 620 },
  height: 360,
  variants: {
    create: {
      note: "The new-agent card: task, project, agent. No machine field; the chip says what Auto will do.",
      props: { surface: "create", state: { kind: "local" } },
    },
    "create-suffix": {
      note: "The same card with the other wording, Cloud (auto), for the open taste question.",
      props: { surface: "create", state: { kind: "preparing", seconds: 3 }, wording: "suffix" },
    },
    local: {
      note: "Auto kept the agent on this Mac, which has room. Free, and the chip says so.",
      props: { surface: "chip", state: { kind: "local" } },
    },
    "cloud-awake": {
      note: "Auto moved it to Cloud and sized it; shape and awake state are shown once it has a cloud computer.",
      props: { surface: "chip", state: { kind: "cloud-awake", vcpu: 4, gb: 8 } },
    },
    sleeping: {
      note: "Sleeping between turns; memory and processes kept.",
      props: { surface: "chip", state: { kind: "cloud-sleeping" } },
    },
    moving: {
      note: "A move in flight: bounded, with elapsed seconds and Cancel (RFD 0074 rule 2).",
      props: { surface: "chip", state: { kind: "moving", to: "Cloud", seconds: 6 } },
    },
    "move-failed": {
      note: "Interrupted migration: the chat is still where it was, and Retry is one click.",
      props: { surface: "popover", state: { kind: "move-failed", reason: "The network dropped during the move." } },
    },
    "spend-paused": {
      note: "Monthly limit reached: cloud agents pause, never stop.",
      props: { surface: "popover", state: { kind: "spend-paused", limit: "$50" } },
    },
    popover: {
      note: "The chip opened on a cloud agent: Where, Size and Sleep each default to Auto; one line says why it is where it is.",
      props: { surface: "popover", state: { kind: "cloud-awake", vcpu: 4, gb: 8 } },
    },
    pinned: {
      note: "A person pinned size and place: no Auto in the label, and the popover shows the pins.",
      props: { surface: "popover", state: { kind: "pinned", vcpu: 8, gb: 32 } },
    },
  },
});
