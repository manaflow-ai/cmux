// l10n-allow-file: gallery captions, not shipped copy.
//
// RFD 0080's Computer panel ("Computer details" in the popover) in its states: a local agent, cloud
// awake with five computers in its history, cloud asleep, a pinned size, and the "What survives
// what" table as a one-line-per-row list, a full table, and a collapsible section.
import { componentEntry } from "../../../gallery/format";
import { ComputerPanel, type ComputerPanelViewProps } from "./ComputerPanel";

const T = Date.UTC(2026, 10, 24, 14, 2);
const min = (n: number) => T + n * 60_000;
const base = {
  agent_name: "fix-login-redirect",
  session_id: "ses_7f3a91",
  time_zone: "UTC",
  locale: "en-US",
} as const;

const LOCAL: ComputerPanelViewProps = {
  ...base,
  home: "this_mac",
  size: { mode: "auto" },
  sleep: { mode: "auto" },
  history: [],
};
const FIVE: ComputerPanelViewProps["history"] = [
  { at_ms: min(-300), change: "moved_to_cloud", reason: "mac_memory_pressure", vm_id: "vm-3k9q" },
  { at_ms: min(-210), change: "resized_up", reason: "grew_for_memory", command: "cargo build", vm_id: "vm-3k9q" },
  { at_ms: min(-120), change: "lost", reason: "slots_full", vm_id: "vm-3k9q" },
  { at_ms: min(-118), change: "moved_to_cloud", reason: "person_moved", vm_id: "vm-8w2d" },
  { at_ms: min(-30), change: "resized_down", reason: "mac_busy", vm_id: "vm-p41x" },
];
const AWAKE: ComputerPanelViewProps = {
  ...base,
  home: "cloud",
  shape: { vcpu: 2, memory_gib: 4 },
  size: { mode: "auto" },
  sleep: { mode: "auto" },
  history: FIVE,
  minutes_awake_today: 85,
};

type Props = ComputerPanelViewProps;

function Board(props: Props) {
  return (
    <div className="computer-panel-board" style={{ padding: 16 }}>
      <ComputerPanel {...props} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.computer-panel",
  title: "RFD 0080 Computer panel",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/auto/ComputerPanel.tsx#ComputerPanel"],
  styles: () => Promise.all([import("../../../ui/ghost.css"), import("../styles.css"), import("./computerPanel.css")]),
  load: async () => Board,
  widths: { normal: 560, wide: 760 },
  height: 640,
  anchors: [{ selector: ".computer-panel" }],
  variants: {
    local: { note: "Agent on this Mac: no size, cost line says on your Mac · free, no history.", props: LOCAL },
    "cloud-awake": {
      note: "Cloud, awake: size now, 1 h 25 min today, five computers in its history; the computer id shows only here.",
      props: AWAKE,
      height: 960,
    },
    "cloud-asleep": {
      note: "Cloud, asleep: same panel, nothing is running; sleep is Auto.",
      props: { ...AWAKE, history: FIVE.slice(0, 2), minutes_awake_today: 12 },
    },
    pinned: {
      note: "Size pinned and kept awake until 16:30: each shows a pin on its row.",
      props: {
        ...AWAKE,
        size: { mode: "pinned", vcpu: 4, memory_gib: 8 },
        sleep: { mode: "keep_awake", until_ms: min(148) },
      },
    },
    "keep-awake-forever": {
      note: "Kept awake until the person says.",
      props: { ...AWAKE, sleep: { mode: "keep_awake" }, history: FIVE.slice(0, 1) },
    },
    "survives-list": {
      note: "Layout A: What survives what as one line per row.",
      props: { ...AWAKE, history: FIVE.slice(0, 1), survives_layout: "list" },
    },
    "survives-table": {
      note: "Layout B: the full table, events by columns, with the short notes.",
      props: { ...AWAKE, history: FIVE.slice(0, 1), survives_layout: "table" },
      height: 760,
    },
    "survives-collapsible": {
      note: "Layout C: What survives what folded away until asked for.",
      props: { ...AWAKE, history: FIVE.slice(0, 1), survives_layout: "collapsible" },
    },
  },
});
