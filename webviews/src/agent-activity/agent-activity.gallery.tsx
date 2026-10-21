// l10n-allow-file: gallery fixtures (sample sessions), not shipped UI.
// Agent Activity (cmux://agent-activity): the page's view over fixture states, with no host bridge
// (screenshots stay placeholders). Empty on a Mac where computer use never ran, and three agents
// across two machines in each layout.
import { useEffect, useState } from "react";
import { minutesAgo } from "../gallery/clock";
import { componentEntry } from "../gallery/format";
import {
  initialActivityState,
  reduceActivity,
  type ActivityEvent,
  type ActivitySession,
  type ActivityState,
} from "./model";
import type { Lane } from "./lanes";
import { ActivityView } from "./view";

type Props = { state: ActivityState };

const now = Date.UTC(2026, 9, 13, 9, 30);

function session(
  id: string,
  machine: string,
  agentName: string,
  label: string,
  extra: Partial<ActivitySession>,
): ActivitySession {
  return {
    id,
    machine,
    machineName: machine === "local" ? "This Mac" : "build-mini",
    label,
    agentKind: "claude",
    agentName,
    attribution: "credential",
    colorHex: "#5b8def",
    targetApps: ["Safari"],
    status: "active",
    startedAt: now - 600_000,
    lastActionAt: now - 5_000,
    acts: 12,
    observes: 30,
    errors: 0,
    foregroundOnly: false,
    ...extra,
  };
}

function events(count: number, bad?: number): ActivityEvent[] {
  const kinds = ["screenshot", "click", "type", "scroll", "key"];
  return Array.from({ length: count }, (_, index) => ({
    seq: index + 1,
    time: now - (count - index) * 4_000,
    kind: kinds[index % kinds.length]!,
    tool: index % 2 ? "computer" : undefined,
    ok: index !== bad,
  }));
}

const empty: ActivityState = { ...initialActivityState(), connections: { local: "not_started" } };

const busy: ActivityState = {
  ...initialActivityState(),
  sessionsByMachine: {
    local: [
      session("s1", "local", "Claude Code", "Book the team offsite", {}),
      session("s2", "local", "Codex", "Fill the expense form", {
        status: "paused",
        colorHex: "#c27bd6",
        lastActionAt: now - 90_000,
      }),
    ],
    mini: [
      session("s3", "mini", "Claude Code", "Check the release notes", {
        status: { ended: "Stopped by you" },
        colorHex: "#4caf7d",
        lastActionAt: now - 900_000,
      }),
    ],
  },
  machineNames: { local: "This Mac", mini: "build-mini" },
  connections: { local: "connected", mini: "connected" },
  eventsBySession: { s1: events(9, 6), s2: events(4), s3: events(14) },
  selectedSessionID: "s1",
};

const hoursAgo = (n: number) => minutesAgo(n * 60);
const lanes: Lane[] = [
  {
    id: "chief",
    name: "chief",
    title: "Coordinator",
    state: "working",
    since: hoursAgo(0.1),
    harness: "claude",
    step: "Check the four open PRs and send the green ones to merge",
  },
  {
    id: "l1",
    name: "op-restore",
    title: "Restore everything",
    parent: "chief",
    state: "failed",
    since: hoursAgo(3),
    error: "Credit balance too low",
  },
  {
    id: "l2",
    name: "op-keys",
    title: "Keymaps call",
    parent: "chief",
    state: "input",
    since: hoursAgo(0.2),
    harness: "codex",
    step: "Should Cmd-K open the palette or clear the terminal?",
  },
  {
    id: "l3",
    name: "op-gallery",
    title: "Gallery previews",
    parent: "chief",
    state: "idle",
    since: hoursAgo(5),
    harness: "claude",
    step: "Opened #21700; CI is green.",
  },
  {
    id: "l4",
    name: "op-cursors",
    title: "Agent Activity lanes",
    parent: "chief",
    state: "working",
    since: hoursAgo(0.5),
    harness: "codex",
    step: "Run the lanes tests",
  },
  { id: "l5", name: "scratch", title: "Scratch chat", state: "idle", since: hoursAgo(26) },
  { id: "l6", name: "mini/op-web", title: "Web bundles", peer: "mini", state: "lost", since: hoursAgo(4) },
];

function ActivityGallery({ state: initial }: Props) {
  const [state, setState] = useState(initial);
  // A new variant replaces the state even when the stage keeps this component mounted.
  useEffect(() => setState(initial), [initial]);
  return (
    <div style={{ height: "100%" }}>
      <ActivityView state={state} dispatch={(action) => setState((current) => reduceActivity(current, action))} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.agent-activity",
  title: "Agent Activity",
  area: "Pages",
  height: 560,
  widths: { narrow: 480, normal: 1000, wide: 1400 },
  covers: ["agent-activity/view.tsx#ActivityView"],
  load: async () => ActivityGallery,
  styles: async () => {
    await import("../pages/shared/desktop.css");
    await import("./styles.css");
  },
  variants: {
    empty: { note: "No computer use yet on This Mac; the machine says why.", props: { state: empty } },
    split: { note: "Three agents on two machines; the first is selected.", props: { state: busy } },
    timeline: { note: "Every session as a lane of steps.", props: { state: { ...busy, layout: "timeline" } } },
    grid: { note: "One tile per session with its latest step.", props: { state: { ...busy, layout: "grid" } } },
    lanes: {
      note: "Labs: every agent session by machine and coordinator, with its harness and current step; what needs a person first.",
      props: { state: { ...busy, lanes } },
    },
  },
});
