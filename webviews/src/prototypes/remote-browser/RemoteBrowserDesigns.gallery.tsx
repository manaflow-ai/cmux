// l10n-allow-file: gallery design fixtures, not shipped UI.
// Browse on a machine (Leo, 2026-11-21): where a tab runs, how it says it runs on a VM, its latency and state.
// Spec: docs/remote-browser-machine-picker.md. Three designs x their states; Leo picks one, then it is built in
// the native browser (AddressBarView, MachineBadgeView, the tab strip) behind DEBUG.
// Recommended: chip (the omnibar chip is the label and the picker, as an editor's remote indicator is).
import { componentEntry } from "../../gallery/format";
import type { PickerMachine, RemoteBrowserDesignsProps } from "./RemoteBrowserDesigns";

const cloud: PickerMachine = {
  id: "cloud-1",
  name: "cloud-1",
  color: "#8e4ec6",
  kind: "Cloud",
  rttMs: 38,
  quality: "good",
};
const slowCloud: PickerMachine = { ...cloud, rttMs: 212, quality: "poor" };
const machines: PickerMachine[] = [
  cloud,
  { id: "build-box", name: "build-box", color: "#12a594", kind: "Linux", rttMs: 74, quality: "fair" },
  { id: "cloud-2", name: "cloud-2", color: "#e5484d", kind: "Cloud", note: "asleep, wakes on use" },
  { id: "studio", name: "studio", color: "#3e63dd", kind: "Mac", note: "no browser host", disabled: true },
];

const base = {
  machine: cloud,
  machines,
  url: "news.ycombinator.com",
  pageTitle: "Hacker News",
  macMemory: "28 MB",
  machineMemory: "410 MB",
  machineCpu: "6%",
} satisfies Omit<RemoteBrowserDesignsProps, "design" | "state">;

export default componentEntry<RemoteBrowserDesignsProps>({
  id: "prototypes.remote-browser",
  title: "Browse on a machine: picker and remote tab",
  area: "Browser",
  experimental: true,
  height: 460,
  keywords: ["remote", "browser", "machine", "vm", "cloud", "latency", "picker", "omnibar", "offload"],
  covers: ["prototypes/remote-browser/RemoteBrowserDesigns.tsx"],
  load: () => import("./RemoteBrowserDesigns").then((module) => module.RemoteBrowserDesigns),
  variants: {
    "chip-live": {
      note: "Recommended. A: the omnibar chip names the machine with a latency dot; the tab has a leading bar in its color",
      props: { ...base, design: "chip", state: "live" },
    },
    "chip-menu": {
      note: "A: the chip's menu is the picker: This Mac, machines, ms, what each side pays",
      props: { ...base, design: "chip", state: "live", menuOpen: true },
    },
    "chip-slow": {
      note: "A: over 150 ms the dot turns red; the number stays in the hover and menu",
      props: { ...base, machine: slowCloud, design: "chip", state: "slow" },
    },
    "chip-paused": {
      note: "A: the machine is unreachable: the last frame dimmed, Reconnect and Open on This Mac",
      props: { ...base, design: "chip", state: "paused" },
    },
    "chip-local": {
      note: "A: a local tab: the chip says This Mac and still opens the picker",
      props: { ...base, design: "chip", state: "local" },
    },
    "line-live": {
      note: "B: containers: a colored underline on the tab, a machine segment before the address, ms at its end",
      props: { ...base, design: "line", state: "live" },
    },
    "line-menu": {
      note: "B: the segment opens the picker",
      props: { ...base, design: "line", state: "live", menuOpen: true },
    },
    "line-starting": {
      note: "B: the host starts; the typed address waits",
      props: { ...base, design: "line", state: "starting" },
    },
    "bar-live": {
      note: "C: remote desktop: a connection bar under the toolbar with signal bars, ms, memory and Move to This Mac",
      props: { ...base, design: "bar", state: "live" },
    },
    "bar-slow": {
      note: "C: slow link: one red bar",
      props: { ...base, machine: slowCloud, design: "bar", state: "slow" },
    },
    "bar-paused": {
      note: "C: unreachable: the bar turns red, the page keeps its last frame",
      props: { ...base, design: "bar", state: "paused" },
    },
  },
});
