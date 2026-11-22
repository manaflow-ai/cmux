// l10n-allow-file: public-safe gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { PerfPanel } from "./PerfPanel";
import { AcpmuxPerf } from "./perf";
import { PerfReporter } from "./perfReporter";
import { AcpWireLog } from "./wire";

type State = "off" | "on" | "quiet";

const NOW = Date.UTC(2026, 10, 18, 9, 30, 0);

const EVENTS = [
  {
    kind: "span",
    seq: 1,
    at: NOW - 40_000,
    name: "page load",
    ms: 620,
    budgetMs: 800,
    over: false,
    parts: [
      { name: "connect start", startMs: 0, ms: 90 },
      { name: "connected", startMs: 90, ms: 210 },
      { name: "transcript mount", startMs: 300, ms: 110 },
      { name: "first paint", startMs: 410, ms: 210 },
    ],
  },
  {
    kind: "span",
    seq: 2,
    at: NOW - 20_000,
    name: "new chat",
    ms: 4_180,
    budgetMs: 3_000,
    over: true,
    parts: [
      { name: "handshake", startMs: 0, ms: 380 },
      { name: "composer ready", startMs: 380, ms: 60 },
      { name: "first token", startMs: 440, ms: 3_740 },
    ],
  },
  {
    kind: "note",
    seq: 3,
    at: NOW - 19_000,
    text: "New chat took 4.2 s to its first token, higher than the 3 s expected; most of it was the agent's first reply.",
  },
  {
    kind: "span",
    seq: 4,
    at: NOW - 8_000,
    name: "workspace switch",
    ms: 64,
    budgetMs: 100,
    over: false,
    parts: [
      { name: "first frame", startMs: 0, ms: 16 },
      { name: "settled", startMs: 16, ms: 48 },
    ],
  },
  {
    kind: "note",
    seq: 5,
    at: NOW - 5_000,
    text: "The session list was sent 7 times in a minute, 31 MB in all.",
    quietedBefore: 3,
  },
  {
    kind: "meter",
    seq: 6,
    at: NOW - 1_000,
    top: [
      {
        channel: "daemon-ipc",
        label: "session/list",
        bytesPerMinute: 31 * 1024 * 1024,
        bytes: 31 * 1024 * 1024,
        count: 7,
        largest: 4.5 * 1024 * 1024,
      },
      {
        channel: "disk-read",
        label: "chat log",
        bytesPerMinute: 2_400_000,
        bytes: 2_400_000,
        count: 3,
        largest: 900_000,
      },
      {
        channel: "webview-bridge",
        label: "_acpmux/events",
        bytesPerMinute: 84_000,
        bytes: 84_000,
        count: 40,
        largest: 9_000,
      },
    ],
  },
];

function fixtureSend(state: State) {
  return async (params: Record<string, unknown>): Promise<unknown> => {
    const on = state !== "off";
    if (params.op === "status") return on ? { on, seq: 6 } : { on };
    if (params.op === "read")
      return params.after === 0 ? { on, events: state === "on" ? EVENTS : [], seq: 6 } : new Promise(() => undefined);
    return { on };
  };
}

/// A reporter that measures nothing: the gallery page is not a chat.
const reporter = new PerfReporter({
  perf: new AcpmuxPerf(),
  wire: new AcpWireLog(),
  now: () => 0,
  wall: () => 0,
  every: () => 1,
  stopEvery: () => undefined,
  frame: () => 1,
  cancelFrame: () => undefined,
  observe: () => undefined,
});

function PerfTab({ state }: { state: State }) {
  const [send] = useState(() => fixtureSend(state));
  return (
    <section className="acpmux-inspector">
      <PerfPanel send={send} reporter={reporter} copy={async () => true} />
    </section>
  );
}

export default componentEntry({
  id: "agent-pane.inspector-perf",
  title: "Inspector Perf tab",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 380, normal: 760, wide: 980 },
  covers: ["agent-session/acpmux/PerfPanel.tsx#PerfPanel"],
  load: async () => PerfTab,
  styles: () => Promise.all([import("../shared/styles.css"), import("./styles.css")]),
  variants: {
    off: { props: { state: "off" }, note: "The watch is off by default: the switch and what turning it on does." },
    on: {
      props: { state: "on" },
      note: "Notes newest first; spans as a waterfall against their budget (the new chat over it); the hot zones.",
    },
    quiet: { props: { state: "quiet" }, note: "On with nothing measured yet." },
  },
});
