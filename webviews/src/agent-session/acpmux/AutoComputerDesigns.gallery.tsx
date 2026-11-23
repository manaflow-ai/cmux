// l10n-allow-file: gallery fixtures for AUTO computers (cmuxterm-hq RFD 0080), not shipped UI.
// Leo, 2026-11-23: "if you pick our fucking auto mode, which is our default mode, right? And we want
// to make that default glaringly obvious". The Where button is RFD 0078's Hybrid control, unchanged and
// never showing a size; a status line beside it says what AUTO is doing, and its popover adds Size,
// Sleep and Why rows. The new-agent card asks for a task and a project only.
import { componentEntry } from "../../gallery/format";
import type { AutoComputerDesignsProps } from "./AutoComputerDesigns";

export default componentEntry<AutoComputerDesignsProps>({
  id: "agent-pane.auto-computer-designs",
  title: "AUTO computers: status line and popover rows on the Hybrid button (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/AutoComputerDesigns.tsx#AutoComputerDesigns"],
  styles: () => Promise.all([import("./styles.css"), import("./composerStates.css")]),
  load: () => import("./AutoComputerDesigns").then((module) => module.AutoComputerDesigns),
  widths: { narrow: 400, normal: 620 },
  height: 420,
  variants: {
    create: {
      note: "The new-agent card: task, project, agent. No machine field; Hybrid is the default.",
      props: { surface: "create", state: { kind: "local" } },
    },
    "create-preparing": {
      note: "Auto chose Cloud at Start: the status line counts while the model is already answering.",
      props: { surface: "create", state: { kind: "preparing", seconds: 3 } },
    },
    local: {
      note: "Running where it is: no status line, and the button never shows a size.",
      props: { surface: "button", state: { kind: "local" } },
    },
    sleeping: {
      note: "Sleeping between turns in Cloud; memory and processes kept.",
      props: { surface: "button", state: { kind: "cloud-sleeping" } },
    },
    moving: {
      note: "A move in flight: bounded, with elapsed seconds and Cancel (RFD 0074 rule 2).",
      props: { surface: "button", state: { kind: "moving", to: "Cloud", seconds: 6 } },
    },
    "move-failed": {
      note: "Interrupted migration: still where it was, Retry is one click, and Why says what happened.",
      props: { surface: "popover", state: { kind: "move-failed", reason: "The network dropped during the move." } },
    },
    "spend-paused": {
      note: "Overage limit reached: cloud agents pause, never stop.",
      props: { surface: "popover", state: { kind: "spend-paused" } },
    },
    popover: {
      note: "Opened on a cloud agent: RFD 0078's rows first, then Size and Sleep on Auto and one Why line.",
      props: { surface: "popover", state: { kind: "cloud-awake", vcpu: 4, gb: 8 } },
    },
    "keep-running": {
      note: "Hybrid chosen again lights Keep running (RFD 0078 high priority).",
      props: { surface: "popover", state: { kind: "cloud-awake", vcpu: 4, gb: 8 }, keepRunning: true },
    },
    pinned: {
      note: "Size pinned in the popover; the button is unchanged and Auto still picks where and when.",
      props: { surface: "popover", state: { kind: "pinned", vcpu: 8, gb: 16 } },
    },
  },
});
