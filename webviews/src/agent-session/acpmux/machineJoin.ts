import { useSyncExternalStore } from "react";

/// Door A (cmuxterm-hq docs/design/remote-spin-up.md, section 2.1): the composer's machine menu
/// lists the machines this Mac reaches but has not added, and one click joins one and picks it for
/// the chat. acpmux does the work (`_acpmux/machine_candidates`, `_acpmux/machine_join_ssh`,
/// acpmux server/machine_join_ssh.rs); this file only keeps what the page shows of it: the rows,
/// and the one join this page started, with its step, its time and how it ended.
///
/// The page never holds the person's access token: the app adds it to the join on its way to
/// acpmux (AgentPaneTransport `machineJoinToken`). One click joins without asking only a node the
/// tailnet says is this person's (`mine`); any other host answers `needs_confirmation` and runs
/// nothing until the person confirms it by name and login.

/// A machine this Mac reaches and has not added (`_acpmux/machine_candidates` `candidates[]`).
export type JoinCandidate = {
  name: string;
  /// What ssh dials (a tailnet DNS name, or a `~/.ssh/config` alias).
  address: string;
  os?: string;
  found: "tailnet" | "ssh-config";
  /// A node the tailnet says this person owns. Only these join on one click.
  mine: boolean;
};

/// A join's steps, in order (acpmux cli/ssh_join.rs `Step`).
export type JoinStep = "reach" | "token" | "install" | "connect";
export const JOIN_STEPS: readonly JoinStep[] = ["reach", "token", "install", "connect"];

/// Why a join stopped (acpmux cli/ssh_join.rs `Kind`), plus `no_peer`: the machine joined but this
/// Mac's acpmux did not list it in time, and `failed` for any refusal of the call itself.
export type JoinFailure = { kind: string; message: string; next: string };

export type JoinPhase =
  /// Not one of the person's own tailnet nodes: the line asks once, naming the host and login.
  | "confirm"
  | "joining"
  /// The machine reported in; the composer waits for acpmux to list it, then picks it.
  | "joined"
  | "failed";

export type MachineJoin = {
  joinId: string;
  candidate: JoinCandidate;
  phase: JoinPhase;
  step: JoinStep;
  /// The step's seconds as acpmux last said them, and when the page heard it (the line counts on).
  seconds: number;
  heardAt: number;
  /// The login ssh would use (`confirm`).
  login?: string;
  /// The person confirmed this host (a retry keeps it).
  confirmed: boolean;
  failure?: JoinFailure;
  /// The name the machine joined as (`machine.name`), which acpmux's peer list uses.
  machine?: string;
  /// A send was held until the machine is picked (the line says so).
  queued: boolean;
};

export type MachineJoinState = {
  candidates: readonly JoinCandidate[];
  /// The list was read once (an empty list then means none, not "not asked yet").
  loaded: boolean;
  join?: MachineJoin;
};

/// How the page reaches acpmux (direct.ts registers its client).
export type MachineJoinPort = {
  candidates(): Promise<unknown>;
  join(params: Record<string, unknown>): Promise<unknown>;
};

const EMPTY: MachineJoinState = { candidates: [], loaded: false };
let state: MachineJoinState = EMPTY;
let port: MachineJoinPort | undefined;
const listeners = new Set<() => void>();
/// What waits for the join's machine to be picked (a held send), by join id.
const pickWaiters = new Map<string, Array<() => void>>();

function publish(next: MachineJoinState): void {
  state = next;
  for (const listener of listeners) listener();
}

function setJoin(join: MachineJoin | undefined): void {
  publish(join ? { ...state, join } : { candidates: state.candidates, loaded: state.loaded });
}

/// The client that answers this page's acpmux calls; undefined when it closes.
export function setMachineJoinPort(next: MachineJoinPort | undefined): void {
  port = next;
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

/// The rows of a `_acpmux/machine_candidates` answer; anything malformed is left out.
export function candidatesFromReply(reply: unknown): JoinCandidate[] {
  const rows = (reply as { candidates?: unknown } | undefined)?.candidates;
  if (!Array.isArray(rows)) return [];
  const out: JoinCandidate[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    const raw = (row ?? {}) as Record<string, unknown>;
    const name = text(raw.name);
    const address = text(raw.address) ?? name;
    if (!name || !address || seen.has(address.toLowerCase())) continue;
    seen.add(address.toLowerCase());
    const os = text(raw.os);
    out.push({
      name,
      address,
      ...(os ? { os } : {}),
      found: raw.found === "tailnet" ? "tailnet" : "ssh-config",
      mine: raw.found === "tailnet" && raw.mine === true,
    });
  }
  return out;
}

/// Yours first (the person's own tailnet nodes, one click each), then every other host, which asks
/// once before it joins; each part by name.
export function splitCandidates(candidates: readonly JoinCandidate[]): {
  mine: JoinCandidate[];
  other: JoinCandidate[];
} {
  const byName = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const sorted = [...candidates].sort((a, b) => byName.compare(a.name, b.name));
  return { mine: sorted.filter((c) => c.mine), other: sorted.filter((c) => !c.mine) };
}

/// Reads the list again (the machine menu opened, or every few seconds while it is open). A failed
/// read keeps the last list: a daemon without `machine-join-ssh-v1` simply shows no rows.
export async function refreshJoinCandidates(): Promise<void> {
  if (!port) return;
  try {
    const reply = await port.candidates();
    publish({ ...state, candidates: candidatesFromReply(reply), loaded: true });
  } catch {
    if (!state.loaded) publish({ ...state, loaded: true });
  }
}

let joins = 0;
const newJoinId = () => `join-${Date.now().toString(36)}-${(joins += 1)}`;

/// One click on a row: the join starts and the machine is the chat's pick. `confirmed`: the person
/// confirmed this host by name and login (any host that is not their own tailnet node).
export function startJoin(candidate: JoinCandidate, confirmed = false, now: number = Date.now()): string {
  const joinId = newJoinId();
  const previous = state.join;
  setJoin({
    joinId,
    candidate,
    phase: "joining",
    step: "reach",
    seconds: 0,
    heardAt: now,
    confirmed,
    queued: previous?.candidate.address === candidate.address ? previous.queued : false,
  });
  const call = port;
  if (!call) {
    settle(joinId, { ok: false, failure: { kind: "failed", message: "", next: "" } });
    return joinId;
  }
  call
    .join({
      host: candidate.address,
      name: candidate.name,
      joinId,
      ...(confirmed ? { confirmed: true } : {}),
    })
    .then(
      (reply) => settle(joinId, reply),
      (error: unknown) =>
        settle(joinId, {
          ok: false,
          failure: {
            // The host refuses a join with no sign-in itself (AgentPaneTransport+MachineJoin.swift).
            kind: (error as { reason?: unknown } | undefined)?.reason === "not_signed_in" ? "not_signed_in" : "failed",
            message: (error as { message?: unknown } | undefined)?.message?.toString() ?? "",
            next: "",
          },
        }),
    );
  return joinId;
}

/// The join's answer: done, a host to confirm, or a failure with its next step.
export function settle(joinId: string, reply: unknown, now: number = Date.now()): void {
  const join = state.join;
  if (!join || join.joinId !== joinId) return;
  const raw = (reply ?? {}) as {
    ok?: unknown;
    seconds?: unknown;
    machine?: { name?: unknown };
    failure?: { kind?: unknown; message?: unknown; next?: unknown };
    confirm?: { login?: unknown };
  };
  const seconds = typeof raw.seconds === "number" && Number.isFinite(raw.seconds) ? raw.seconds : join.seconds;
  if (raw.ok === true) {
    setJoin({
      ...join,
      phase: "joined",
      step: "connect",
      seconds,
      heardAt: now,
      machine: text(raw.machine?.name) ?? join.candidate.name,
    });
    return;
  }
  const kind = text(raw.failure?.kind) ?? "failed";
  if (kind === "needs_confirmation" && !join.confirmed) {
    const login = text(raw.confirm?.login);
    setJoin({ ...join, phase: "confirm", seconds: 0, heardAt: now, ...(login ? { login } : {}) });
    return;
  }
  fail(join, { kind, message: text(raw.failure?.message) ?? "", next: text(raw.failure?.next) ?? "" });
}

function fail(join: MachineJoin, failure: JoinFailure): void {
  // A held send stays in the composer, its draft as typed: it is not sent anywhere else.
  pickWaiters.delete(join.joinId);
  setJoin({ ...join, phase: "failed", failure });
}

/// `_acpmux/machine_join_progress {joinId, host, step, state, detail, seconds}`.
export function noteJoinProgress(params: unknown, now: number = Date.now()): void {
  const raw = (params ?? {}) as { joinId?: unknown; step?: unknown; seconds?: unknown };
  const join = state.join;
  if (!join || join.phase !== "joining" || raw.joinId !== join.joinId) return;
  const step = JOIN_STEPS.find((candidate) => candidate === raw.step) ?? join.step;
  const seconds = typeof raw.seconds === "number" && Number.isFinite(raw.seconds) ? raw.seconds : join.seconds;
  setJoin({ ...join, step, seconds, heardAt: now });
}

/// The person confirmed the host the line named: the join runs, confirmed.
export function confirmJoin(): void {
  const join = state.join;
  if (join?.phase === "confirm") startJoin(join.candidate, true);
}

/// The failure line's Try Again: the same host, confirmed as before.
export function retryJoin(): void {
  const join = state.join;
  if (join && join.phase === "failed") startJoin(join.candidate, join.confirmed);
}

/// The machine joined, but this Mac's acpmux did not list it in time.
export function joinNotListed(joinId: string): void {
  const join = state.join;
  if (join?.joinId === joinId && join.phase === "joined") fail(join, { kind: "no_peer", message: "", next: "" });
}

/// The line goes away: Cancel on the confirmation, Dismiss on a failure, or another machine
/// picked. A join that still runs goes on in acpmux; the page only stops waiting for it.
export function endJoin(): void {
  const join = state.join;
  if (!join) return;
  pickWaiters.delete(join.joinId);
  setJoin(undefined);
}

/// The composer picked the joined machine: a held send goes now, and the line goes away.
export function joinPicked(joinId: string): void {
  const join = state.join;
  if (!join || join.joinId !== joinId) return;
  const waiters = pickWaiters.get(joinId) ?? [];
  pickWaiters.delete(joinId);
  setJoin(undefined);
  if (waiters.length === 0) return;
  // After the frame that shows the pick: the composer's send then reads the chat's new machine.
  const run = () => setTimeout(() => waiters.forEach((waiter) => waiter()), 0);
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(run);
  else run();
}

/// Holds a send while a join runs for the chat: true when it was held, and `again` runs once the
/// machine is picked (the composer then sends to it). False when no join waits.
export function holdSendForJoin(again: () => void): boolean {
  const join = state.join;
  if (!join || join.phase === "failed") return false;
  // One held send per join: the latest Send is the one that goes.
  pickWaiters.set(join.joinId, [again]);
  if (!join.queued) setJoin({ ...join, queued: true });
  return true;
}

/// The joined machine's row among acpmux's machines (by the name it joined as, or the host's first
/// label), once it can take a chat.
export function arrivedMachine<T extends { id: string; label: string; kind: string }>(
  join: MachineJoin | undefined,
  computers: readonly T[],
  ready: (computer: T) => boolean,
): T | undefined {
  if (!join || join.phase !== "joined") return undefined;
  const names = new Set(
    [join.machine, join.candidate.name, join.candidate.address.split(".")[0]]
      .filter((name): name is string => Boolean(name))
      .map((name) => name.toLowerCase()),
  );
  return computers.find(
    (computer) => computer.kind !== "local" && names.has(computer.label.toLowerCase()) && ready(computer),
  );
}

/// The seconds the line shows: acpmux's, counted on from when the page heard them.
export function joinSeconds(join: MachineJoin, now: number): number {
  return Math.max(0, Math.floor(join.seconds + (now - join.heardAt) / 1000));
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const snapshot = () => state;

export function useMachineJoinState(): MachineJoinState {
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

/// Tests and the gallery.
export function setMachineJoinStateForTest(next: MachineJoinState | undefined): void {
  pickWaiters.clear();
  publish(next ?? EMPTY);
}
export function machineJoinStateForTest(): MachineJoinState {
  return state;
}
