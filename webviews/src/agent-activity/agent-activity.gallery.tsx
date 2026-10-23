// l10n-allow-file: gallery fixtures (sample sessions), not shipped UI.
// Agent Activity (cmux://agent-activity): the page's view over fixture states, with no host bridge
// (screenshots stay placeholders). Empty on a Mac where computer use never ran, and three agents
// across two machines in each layout.
import { useEffect, useState } from "react";
import { componentEntry } from "../gallery/format";
import {
  initialActivityState,
  reduceActivity,
  type ActivityEvent,
  type ActivitySession,
  type ActivityState,
} from "./model";
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
  covers: ["page:cmux.agent-activity", "agent-activity/view.tsx#ActivityView"],
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
  },
});
