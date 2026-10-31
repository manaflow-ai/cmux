// l10n-allow-file: gallery fixtures (sample sessions), not shipped UI.
// Agent Activity (cmux://agent-activity): the page's view over fixture states, with no host bridge;
// screenshots are drawn here (fixtureFrame) in place of the host's. Empty on a Mac where computer use
// never ran, three agents across two machines in each layout, and the frame viewer: inline on the
// newest or an earlier frame, a session with no screenshots, and opened over the grid.
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
import type { FrameLoader } from "./viewer";

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

/** A session's steps as the helper logs them: an app launch (no pixels), then reads and actions that
 * each kept a screenshot, except a key press here and there. `frames: false` keeps none. */
function events(id: string, count: number, bad?: number, frames = true): ActivityEvent[] {
  const tools = ["get_window_state", "click", "type_text", "click", "scroll", "press_key", "click", "drag"];
  const steps: ActivityEvent[] = [
    { seq: 0, time: now - (count + 1) * 4_000, kind: "act", tool: "launch_app", target: "Safari", ok: true },
  ];
  for (let index = 0; index < count; index += 1) {
    const tool = tools[index % tools.length]!;
    steps.push({
      seq: index + 1,
      time: now - (count - index) * 4_000,
      kind: tool === "get_window_state" ? "observe" : "act",
      tool,
      target: "Safari",
      ok: index !== bad,
      afterFrame: frames && tool !== "press_key" ? { blob: `${id}|${index + 1}`, width: 320, height: 200 } : undefined,
    });
  }
  return steps;
}

/** A stand-in screenshot: a window with a title bar, a sidebar and rows, and the step number. */
const fixtureFrame: FrameLoader = async (frame) => {
  const [session = "", step = "0"] = frame.blob.split("|");
  const tint = { s1: "#5b8def", s2: "#c27bd6", s3: "#4caf7d" }[session] ?? "#888888";
  const row = Number(step) % 6;
  const rows = Array.from(
    { length: 6 },
    (_, index) =>
      `<rect x="96" y="${44 + index * 24}" width="${120 + ((index * 37 + Number(step) * 19) % 90)}" height="10" rx="3" fill="${index === row ? "#8a8f98" : "#d4d7dc"}"/>`,
  ).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${frame.width}" height="${frame.height}" viewBox="0 0 320 200"><rect width="320" height="200" fill="#f6f6f7"/><rect width="320" height="22" fill="${tint}"/><rect y="22" width="80" height="178" fill="#e7e8ea"/>${rows}<text x="8" y="15" font-family="-apple-system, sans-serif" font-size="11" font-weight="600" fill="#fff">Safari · step ${step}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
};

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
  eventsBySession: { s1: events("s1", 9, 6), s2: events("s2", 4), s3: events("s3", 14) },
  selectedSessionID: "s1",
};

const noFrames: ActivityState = {
  ...busy,
  eventsBySession: { ...busy.eventsBySession, s1: events("s1", 5, undefined, false) },
};

function ActivityGallery({ state: initial }: Props) {
  const [state, setState] = useState(initial);
  // A new variant replaces the state even when the stage keeps this component mounted.
  useEffect(() => setState(initial), [initial]);
  return (
    <div style={{ height: "100%" }}>
      <ActivityView
        state={state}
        dispatch={(action) => setState((current) => reduceActivity(current, action))}
        loadFrame={fixtureFrame}
      />
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
    await import("../ui/ui.css");
    await import("./styles.css");
  },
  variants: {
    empty: { note: "No computer use yet on This Mac; the machine says why.", props: { state: empty } },
    split: {
      note: "Three agents on two machines; the first is selected, its newest screenshot in the viewer.",
      props: { state: busy },
    },
    "split-earlier-frame": {
      note: "The viewer stepped back to the third screenshot (Previous, the Left arrow, or a filmstrip click).",
      props: { state: { ...busy, scrubSeq: 3 } },
    },
    "split-no-frames": {
      note: "A session whose steps kept no screenshot: the viewer says so and shows no filmstrip.",
      props: { state: noFrames },
    },
    timeline: {
      note: "Every session as a lane of its screenshots; a click opens one in the viewer.",
      props: { state: { ...busy, layout: "timeline" } },
    },
    grid: {
      note: "One tile per session with its newest screenshot.",
      props: { state: { ...busy, layout: "grid" } },
    },
    "grid-viewer": {
      note: "A tile clicked in the grid: the viewer over the page on that session, at its fifth screenshot.",
      props: { state: { ...busy, layout: "grid", selectedSessionID: "s3", scrubSeq: 5, viewing: true } },
    },
  },
});
