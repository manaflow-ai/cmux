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
  id: string; machine: string; machineName: string; label: string; agentKind: string; agentName: string;
  attribution: string; workspaceTitle?: string; terminalTitle?: string; colorHex: string; targetApps: string[];
  status: ActivityStatus; startedAt: number; lastActionAt: number; endedAt?: number; acts: number; observes: number;
  errors: number; foregroundOnly: boolean;
};
export type ActivityGroup = { id: string; name: string; connection: ActivityConnection; sessions: ActivitySession[] };
export type ActivityState = {
  sessionsByMachine: Record<string, ActivitySession[]>;
  machineNames: Record<string, string>;
  connections: Record<string, ActivityConnection>;
  eventsBySession: Record<string, ActivityEvent[]>;
  selectedSessionID?: string;
  scrubSeq?: number;
  filter: string;
  watching: string[];
  lastOperationError?: string;
  layout: "split" | "timeline" | "grid";
  strings: { title: string; filter: string; emptyTitle: string; emptyDetail: string; noFrame: string; active: string; idle: string; paused: string; live: string; stop: string; pause: string; resume: string; watch: string; unwatch: string };
};

export const isLive = (status: ActivityStatus) => typeof status === "string";
export const displayFrame = (event: ActivityEvent) => event.afterFrame ?? event.beforeFrame;

export function matches(session: ActivitySession, filter: string): boolean {
  const needle = filter.trim().toLocaleLowerCase();
  if (!needle) return true;
  return [session.label, session.agentName, session.agentKind, session.workspaceTitle ?? "", session.terminalTitle ?? "", session.machineName, ...session.targetApps]
    .some((value) => value.toLocaleLowerCase().includes(needle));
}

export function listOrder(a: ActivitySession, b: ActivitySession): number {
  if (isLive(a.status) !== isLive(b.status)) return isLive(a.status) ? -1 : 1;
  if (a.lastActionAt !== b.lastActionAt) return b.lastActionAt - a.lastActionAt;
  return a.id.localeCompare(b.id);
}

export function groups(state: ActivityState): ActivityGroup[] {
  const machines = new Set([...Object.keys(state.sessionsByMachine), ...Object.keys(state.connections)]);
  return [...machines].sort((a, b) => {
    if ((a === "local") !== (b === "local")) return a === "local" ? -1 : 1;
    return (state.machineNames[a] ?? a).localeCompare(state.machineNames[b] ?? b);
  }).map((id) => ({
    id, name: state.machineNames[id] ?? id, connection: state.connections[id] ?? "connected",
    sessions: (state.sessionsByMachine[id] ?? []).filter((s) => matches(s, state.filter)).sort(listOrder),
  }));
}

export function selectedEvents(state: ActivityState): ActivityEvent[] {
  return state.selectedSessionID ? state.eventsBySession[state.selectedSessionID] ?? [] : [];
}
export function currentEvent(state: ActivityState): ActivityEvent | undefined {
  const events = selectedEvents(state);
  if (state.scrubSeq === undefined) return events.at(-1);
  return events.find((event) => event.seq === state.scrubSeq) ?? events.at(-1);
}
export function currentFrameEvent(state: ActivityState): ActivityEvent | undefined {
  const events = selectedEvents(state); const current = currentEvent(state);
  if (!current) return undefined;
  const index = events.findIndex((event) => event.seq === current.seq);
  return events.slice(0, index + 1).reverse().find((event) => displayFrame(event) !== undefined);
}

export function reduceActivity(state: ActivityState, action: any): ActivityState {
  let next = state;
  if (action.type === "snapshot") next = { ...state, ...action.state, filter: state.filter, layout: state.layout };
  if (action.type === "sessions") {
    const sessionsByMachine = { ...state.sessionsByMachine, [action.machine]: action.sessions };
    const all = (Object.values(sessionsByMachine) as ActivitySession[][]).flat();
    const selected = state.selectedSessionID && all.some((s) => s.id === state.selectedSessionID)
      ? state.selectedSessionID : groups({ ...state, sessionsByMachine, selectedSessionID: undefined }).flatMap((g) => g.sessions)[0]?.id;
    next = { ...state, sessionsByMachine, machineNames: { ...state.machineNames, [action.machine]: action.sessions[0]?.machineName ?? state.machineNames[action.machine] }, connections: { ...state.connections, [action.machine]: state.connections[action.machine] ?? "connected" }, selectedSessionID: selected, scrubSeq: selected === state.selectedSessionID ? state.scrubSeq : undefined };
  }
  if (action.type === "events") {
    const current = state.eventsBySession[action.session] ?? [];
    const nextSeq = current.at(-1)?.seq === undefined ? 0 : current.at(-1)!.seq + 1;
    const additions = action.events.filter((event: ActivityEvent) => event.seq >= nextSeq);
    next = { ...state, eventsBySession: { ...state.eventsBySession, [action.session]: [...current, ...additions] } };
  }
  if (action.type === "connection") next = { ...state, connections: { ...state.connections, [action.machine]: action.connection } };
  if (action.type === "select") next = { ...state, selectedSessionID: action.id, scrubSeq: undefined };
  if (action.type === "filter") next = { ...state, filter: action.value };
  if (action.type === "layout") next = { ...state, layout: action.value };
  if (action.type === "scrub") {
    const events = selectedEvents(state); next = { ...state, scrubSeq: action.seq === undefined || action.seq === events.at(-1)?.seq || !events.some((e) => e.seq === action.seq) ? undefined : action.seq };
  }
  if (action.type === "follow") next = { ...state, watching: action.ids };
  return next;
}

export const initialActivityState = (): ActivityState => ({ sessionsByMachine: {}, machineNames: {}, connections: {}, eventsBySession: {}, filter: "", watching: [], layout: "split", strings: { title: "Agent Activity", filter: "Filter", emptyTitle: "No computer use yet", emptyDetail: "When an agent uses computer use, its session and a timeline of every action appear here.", noFrame: "No screenshot for this step", active: "Active", idle: "Idle", paused: "Paused", live: "Live", stop: "Stop", pause: "Pause", resume: "Resume", watch: "Watch", unwatch: "Unwatch" } });
