export type ActivityStatus = "active" | "idle" | "paused" | { ended: string };
export type ActivityConnection = "connected" | "not_started" | "not_set_up" | "unreachable";
export type ActivityFrame = { blob: string; width: number; height: number; expired?: boolean };
export type ActivityEvent = {
  seq: number;
  time: number;
  kind: string;
  tool?: string;
  target?: string;
  ok: boolean;
  errorCode?: string;
  durationMs?: number;
  redactedTextLength?: number;
  beforeFrame?: ActivityFrame;
  afterFrame?: ActivityFrame;
  clickPoint?: { x: number; y: number };
};
export type ActivitySession = {
  id: string;
  machine: string;
  machineName: string;
  label: string;
  agentKind: string;
  agentName: string;
  attribution: string;
  workspaceTitle?: string;
  terminalTitle?: string;
  colorHex: string;
  targetApps: string[];
  status: ActivityStatus;
  startedAt: number;
  lastActionAt: number;
  endedAt?: number;
  acts: number;
  observes: number;
  errors: number;
  foregroundOnly: boolean;
};
export type ActivityGroup = { id: string; name: string; connection: ActivityConnection; sessions: ActivitySession[] };
export type ActivityState = {
  sessionsByMachine: Record<string, ActivitySession[]>;
  machineNames: Record<string, string>;
  connections: Record<string, ActivityConnection>;
  eventsBySession: Record<string, ActivityEvent[]>;
  selectedSessionID?: string;
  scrubSeq?: number;
  /** The frame viewer is open over the timeline or grid (this page only; the host never sends it). */
  viewing?: boolean;
  filter: string;
  watching: string[];
  lastOperationError?: string;
  layout: "split" | "timeline" | "grid";
  strings: {
    title: string;
    filter: string;
    emptyTitle: string;
    emptyDetail: string;
    noFrame: string;
    active: string;
    idle: string;
    paused: string;
    live: string;
    stop: string;
    pause: string;
    resume: string;
    watch: string;
    unwatch: string;
    thisMac: string;
    layout: string;
    layoutSplit: string;
    layoutTimeline: string;
    layoutGrid: string;
    notStarted: string;
    notSetUp: string;
    unreachable: string;
    noFrames: string;
    /** "%1$lld of %2$lld": the viewer's position (positionText). */
    position: string;
    previous: string;
    next: string;
    close: string;
    stepClick: string;
    stepType: string;
    stepKeys: string;
    stepOpenApp: string;
    stepReadWindow: string;
    stepListWindows: string;
    stepScroll: string;
    stepDrag: string;
    stepScreenshot: string;
  };
};

/** The size of a frame the page asks the host for: the filmstrip's thumbnails, the viewer's full frame
 * (the host answers with the thumbnail when the session keeps no full frames). */
export type ActivityFrameSize = "thumb" | "full";

/** The words for a machine's connection; nothing while it is connected. */
export function connectionText(connection: ActivityConnection, strings: ActivityState["strings"]): string | undefined {
  if (connection === "not_started") return strings.notStarted;
  if (connection === "not_set_up") return strings.notSetUp;
  if (connection === "unreachable") return strings.unreachable;
  return undefined;
}

export const isLive = (status: ActivityStatus) => typeof status === "string";
export const displayFrame = (event: ActivityEvent) => event.afterFrame ?? event.beforeFrame;

export function normalizeFilter(filter: string): string {
  return filter.trim().toLocaleLowerCase();
}

function matchesNeedle(session: ActivitySession, needle: string): boolean {
  if (!needle) return true;
  return [
    session.label,
    session.agentName,
    session.agentKind,
    session.workspaceTitle ?? "",
    session.terminalTitle ?? "",
    session.machineName,
    ...session.targetApps,
  ].some((value) => value.toLocaleLowerCase().includes(needle));
}

export function matches(session: ActivitySession, filter: string): boolean {
  return matchesNeedle(session, normalizeFilter(filter));
}

export function listOrder(a: ActivitySession, b: ActivitySession): number {
  if (isLive(a.status) !== isLive(b.status)) return isLive(a.status) ? -1 : 1;
  if (a.lastActionAt !== b.lastActionAt) return b.lastActionAt - a.lastActionAt;
  return a.id.localeCompare(b.id);
}

export function groups(state: ActivityState): ActivityGroup[] {
  const needle = normalizeFilter(state.filter);
  const machines = new Set([...Object.keys(state.sessionsByMachine), ...Object.keys(state.connections)]);
  return [...machines]
    .sort((a, b) => {
      if ((a === "local") !== (b === "local")) return a === "local" ? -1 : 1;
      return (state.machineNames[a] ?? a).localeCompare(state.machineNames[b] ?? b);
    })
    .map((id) => ({
      id,
      name: state.machineNames[id] ?? (id === "local" ? state.strings.thisMac : id),
      connection: state.connections[id] ?? "connected",
      sessions: (state.sessionsByMachine[id] ?? []).filter((s) => matchesNeedle(s, needle)).sort(listOrder),
    }));
}

export function selectedEvents(state: ActivityState): ActivityEvent[] {
  return state.selectedSessionID ? (state.eventsBySession[state.selectedSessionID] ?? []) : [];
}
export function currentEvent(state: ActivityState): ActivityEvent | undefined {
  const events = selectedEvents(state);
  if (state.scrubSeq === undefined) return events.at(-1);
  return events.find((event) => event.seq === state.scrubSeq) ?? events.at(-1);
}
export function currentFrameEvent(state: ActivityState): ActivityEvent | undefined {
  const events = selectedEvents(state);
  const current = currentEvent(state);
  if (!current) return undefined;
  const index = events.findIndex((event) => event.seq === current.seq);
  return events
    .slice(0, index + 1)
    .reverse()
    .find((event) => displayFrame(event) !== undefined);
}

/** Every event that kept a screenshot, oldest first: the frames the viewer steps through. */
export function frameEvents(events: readonly ActivityEvent[]): ActivityEvent[] {
  return events.filter((event) => displayFrame(event) !== undefined);
}

/** The viewer's position among the selected session's frames (0 when it has frames but the scrubber is
 * before the first), or -1 when it has none. */
export function frameIndex(state: ActivityState): number {
  const frames = frameEvents(selectedEvents(state));
  if (!frames.length) return -1;
  const current = currentFrameEvent(state);
  return current
    ? Math.max(
        0,
        frames.findIndex((event) => event.seq === current.seq),
      )
    : 0;
}

/** Moves the viewer `delta` frames (clamped to the first and last); ±Infinity goes to either end. */
export function stepFrame(state: ActivityState, delta: number): ActivityState {
  const frames = frameEvents(selectedEvents(state));
  const index = frameIndex(state);
  if (index < 0) return state;
  const target = Math.min(Math.max(index + delta, 0), frames.length - 1);
  if (target === index) return state;
  return reduceActivity(state, { type: "scrub", seq: frames[target]!.seq });
}

/** The step that made a frame, by the tool the agent called; an unknown tool is its own name. */
export function stepLabel(event: ActivityEvent, strings: ActivityState["strings"]): string {
  const tool = event.tool ?? "";
  if (/click/.test(tool)) return strings.stepClick;
  if (/drag/.test(tool)) return strings.stepDrag;
  if (/^(type|set_value|type_text)/.test(tool)) return strings.stepType;
  if (/^(press_key|hotkey|key)/.test(tool)) return strings.stepKeys;
  if (/^(launch_app|open_app|activate_app|open)/.test(tool)) return strings.stepOpenApp;
  if (/^(get_window_state|get_app_state|get_accessibility_tree)/.test(tool)) return strings.stepReadWindow;
  if (/^list_(windows|apps)/.test(tool)) return strings.stepListWindows;
  if (/scroll/.test(tool)) return strings.stepScroll;
  if (/^(screenshot|get_desktop_state|zoom)/.test(tool)) return strings.stepScreenshot;
  const name = (tool || event.kind).replace(/_/g, " ");
  return name.charAt(0).toLocaleUpperCase() + name.slice(1);
}

/** "4 of 12" from the localized "%1$lld of %2$lld" (1-based). */
export function positionText(index: number, count: number, strings: ActivityState["strings"]): string {
  return strings.position.replace(/%1\$(lld|d|@)/, String(index + 1)).replace(/%2\$(lld|d|@)/, String(count));
}

/** The frames the viewer keeps loaded at `index`: that one and its neighbours, by blob (a repeated
 * screenshot is one image). Everything else is dropped, so memory stays three frames however long the
 * session is. */
export function frameWindow(frames: readonly ActivityEvent[], index: number, radius = 1): ActivityFrame[] {
  const kept = new Map<string, ActivityFrame>();
  for (let at = index - radius; at <= index + radius; at += 1) {
    const frame = frames[at] && displayFrame(frames[at]!);
    if (frame && !frame.expired) kept.set(frame.blob, frame);
  }
  return [...kept.values()];
}

export function step(state: ActivityState, delta: number, framesOnly = false): ActivityState {
  const events = framesOnly
    ? selectedEvents(state).filter((event) => displayFrame(event) !== undefined)
    : selectedEvents(state);
  if (!events.length || delta === 0) return state;
  const current = currentEvent(state);
  if (!current) return state;
  let target: number;
  const currentIndex = events.findIndex((event) => event.seq === current.seq);
  if (currentIndex >= 0) {
    target = currentIndex + delta;
  } else if (delta > 0) {
    const next = events.findIndex((event) => event.seq > current.seq);
    if (next < 0) return state;
    target = next + delta - 1;
  } else {
    let previous = -1;
    for (let index = events.length - 1; index >= 0; index -= 1) {
      if (events[index].seq < current.seq) {
        previous = index;
        break;
      }
    }
    if (previous < 0) return state;
    target = previous + delta + 1;
  }
  const clamped = Math.min(Math.max(target, 0), events.length - 1);
  return reduceActivity(state, { type: "scrub", seq: events[clamped].seq });
}

export function reduceActivity(state: ActivityState, action: any): ActivityState {
  let next = state;
  if (action.type === "snapshot")
    next = {
      ...state,
      ...action.state,
      filter: state.filter,
      layout: state.layout,
    };
  if (action.type === "sessions") {
    const sessionsByMachine = { ...state.sessionsByMachine, [action.machine]: action.sessions };
    const all = (Object.values(sessionsByMachine) as ActivitySession[][]).flat();
    const selected =
      state.selectedSessionID && all.some((s) => s.id === state.selectedSessionID)
        ? state.selectedSessionID
        : groups({ ...state, sessionsByMachine, selectedSessionID: undefined }).flatMap((g) => g.sessions)[0]?.id;
    next = {
      ...state,
      sessionsByMachine,
      machineNames: {
        ...state.machineNames,
        [action.machine]: action.sessions[0]?.machineName ?? state.machineNames[action.machine],
      },
      connections: { ...state.connections, [action.machine]: state.connections[action.machine] ?? "connected" },
      selectedSessionID: selected,
      scrubSeq: selected === state.selectedSessionID ? state.scrubSeq : undefined,
    };
  }
  if (action.type === "events") {
    const current = state.eventsBySession[action.session] ?? [];
    const nextSeq = current.at(-1)?.seq === undefined ? 0 : current.at(-1)!.seq + 1;
    const additions = action.events.filter((event: ActivityEvent) => event.seq >= nextSeq);
    next = { ...state, eventsBySession: { ...state.eventsBySession, [action.session]: [...current, ...additions] } };
  }
  if (action.type === "connection")
    next = { ...state, connections: { ...state.connections, [action.machine]: action.connection } };
  if (action.type === "select") next = { ...state, selectedSessionID: action.id, scrubSeq: undefined };
  // A frame clicked in the timeline or grid: its session, that frame, and the viewer over the page.
  if (action.type === "open")
    next = {
      ...reduceActivity(reduceActivity(state, { type: "select", id: action.id }), { type: "scrub", seq: action.seq }),
      viewing: true,
    };
  if (action.type === "close") next = { ...state, viewing: false };
  if (action.type === "filter") next = { ...state, filter: action.value };
  if (action.type === "layout") next = { ...state, layout: action.value };
  if (action.type === "scrub") {
    const events = selectedEvents(state);
    next = {
      ...state,
      scrubSeq:
        action.seq === undefined || action.seq === events.at(-1)?.seq || !events.some((e) => e.seq === action.seq)
          ? undefined
          : action.seq,
    };
  }
  if (action.type === "follow") next = { ...state, watching: action.ids };
  return next;
}

export const initialActivityState = (): ActivityState => ({
  sessionsByMachine: {},
  machineNames: {},
  connections: {},
  eventsBySession: {},
  filter: "",
  watching: [],
  layout: "split",
  strings: {
    title: "Agent Activity",
    filter: "Filter",
    emptyTitle: "No computer use yet",
    emptyDetail: "Sessions and their steps show here when an agent uses the computer.",
    noFrame: "No screenshot for this step",
    active: "Active",
    idle: "Idle",
    paused: "Paused",
    live: "Live",
    stop: "Stop",
    pause: "Pause",
    resume: "Resume",
    watch: "Watch",
    unwatch: "Stop Watching",
    thisMac: "This Mac",
    layout: "Layout",
    layoutSplit: "Split",
    layoutTimeline: "Timeline",
    layoutGrid: "Grid",
    notStarted: "Computer use has not run here yet",
    notSetUp: "Computer use needs Accessibility and Screen Recording",
    unreachable: "Machine unreachable",
    noFrames: "No screenshots yet",
    position: "%1$lld of %2$lld",
    previous: "Previous",
    next: "Next",
    close: "Close",
    stepClick: "Click",
    stepType: "Type",
    stepKeys: "Press Keys",
    stepOpenApp: "Open App",
    stepReadWindow: "Read Window",
    stepListWindows: "List Windows",
    stepScroll: "Scroll",
    stepDrag: "Drag",
    stepScreenshot: "Screenshot",
  },
});
