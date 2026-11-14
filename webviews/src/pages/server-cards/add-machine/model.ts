// The Add Machine card's UI state (plans/cmux-next/add-machine-DESIGN.md), derived from what the
// host relays: which layout shows (pick, running, ready, failed), the checklist folded from the
// run's events, the footer's buttons with their keys, the titles and Copy Details. Pure functions,
// so the card, the gallery and the tests read the same answers.
import { Checklist, KNOWN_STEPS, parseHostLine, type ChecklistRow } from "./checklist";
import type { AddMachineMode, AddMachineRun, HostCandidate, RunEvent } from "./types";

export type Phase = "pick" | "running" | "ready" | "failed";

export type AddMachineAction =
  | "add"
  | "tryAgain"
  | "changeHost"
  | "fix"
  | "openWorkspace"
  | "copyDetails"
  | "done"
  | "cancel";

export interface AddMachineButton {
  action: AddMachineAction;
  key?: "return" | "escape";
  enabled: boolean;
}

/** The layout a run shows: pick with no run (Add Machine's fields), else the run's outcome. */
export function phaseOf(run: AddMachineRun | undefined): Phase {
  if (!run) return "pick";
  return run.outcome;
}

/** The checklist of a run and whether the app is installing its own build now. */
export function foldRun(events: readonly RunEvent[]): { checklist: Checklist; installing: boolean } {
  const checklist = new Checklist();
  let installing = false;
  for (const event of events) {
    switch (event.kind) {
      case "start":
        checklist.start(event.joined ? [] : KNOWN_STEPS);
        break;
      case "line": {
        const line = parseHostLine(event.line);
        if (!line) break;
        if ("report" in line) checklist.finish(line.report);
        else checklist.apply(line.step);
        break;
      }
      case "install":
        installing = true;
        checklist.run("install");
        break;
      case "installEnd":
        installing = false;
        break;
      case "stop":
        installing = false;
        checklist.stop(event.detail);
        break;
    }
  }
  return { checklist, installing };
}

const button = (action: AddMachineAction, key?: "return" | "escape", enabled = true): AddMachineButton => ({
  action,
  ...(key ? { key } : {}),
  enabled,
});

/** The footer: Escape (or no key) first, Return last. */
export function buttons(phase: Phase, mode: AddMachineMode, canAdd: boolean, machineID?: string): AddMachineButton[] {
  if (phase === "pick") return [button("cancel", "escape"), button("add", "return", canAdd)];
  switch (mode.kind) {
    case "add":
      switch (phase) {
        case "running":
          return [button("cancel", "escape"), button("add", "return", false)];
        case "ready":
          return [button("done", "escape"), button("openWorkspace", "return", machineID !== undefined)];
        case "failed":
          return [button("copyDetails"), button("changeHost"), button("tryAgain", "return")];
      }
      break;
    case "check":
      switch (phase) {
        case "running":
          return [button("cancel", "escape"), button("fix", "return", false)];
        case "ready":
          return [button("done", "return")];
        case "failed":
          return [button("copyDetails"), button("fix", "return")];
      }
      break;
    case "checkJoined":
      switch (phase) {
        case "running":
          return [button("cancel", "escape")];
        case "ready":
          return [button("done", "return")];
        case "failed":
          return [button("copyDetails"), button("done", "return")];
      }
  }
  return [];
}

/** Why a peer cannot be picked, in the order a person would fix it, or that it is an agent peer. */
export function badgeKey(candidate: HostCandidate): string | undefined {
  if (candidate.inApp) return "addMachine.candidate.added";
  if (!candidate.online) return "addMachine.candidate.offline";
  if (candidate.alreadyPeer) return "addMachine.candidate.agentPeer";
  if (candidate.sshOK === false) return "addMachine.candidate.sshOff";
  return undefined;
}

const trimmed = (text: string | undefined) => {
  const value = (text ?? "").trim();
  return value === "" ? undefined : value;
};

/** The picked agent peer while the field still holds its destination. */
export function peerTarget(
  picked: HostCandidate | undefined,
  destination: string,
  parsed: unknown,
): HostCandidate | undefined {
  return picked && parsed && destination === picked.destination ? picked : undefined;
}

/** The machine's name when the Name field is empty: the peer's name, else the short host. */
export function defaultName(peer: HostCandidate | undefined, parsedShortName: string | undefined): string {
  if (peer) return trimmed(peer.peer) ?? parsedShortName ?? "";
  return parsedShortName ?? "";
}

/** The name an Add runs under: the field, else the default. */
export function runName(name: string, fallback: string): string {
  return trimmed(name) ?? fallback;
}

/** A step's key in the AddMachine table, or undefined for a step this build does not know. */
export function stepKey(step: string): string | undefined {
  const known: Record<string, string> = {
    reach: "addMachine.step.reach",
    install: "addMachine.step.install",
    daemon: "addMachine.step.daemon",
    harness: "addMachine.step.harness",
    update: "addMachine.step.update",
    peer: "addMachine.step.peer",
    "peer-back": "addMachine.step.peerBack",
    identity: "addMachine.step.identity",
    approvals: "addMachine.step.approvals",
    binary: "addMachine.step.binary",
    service: "addMachine.step.service",
    credential: "addMachine.step.credential",
    revoked: "addMachine.step.revoked",
    hub: "addMachine.step.hub",
    heartbeat: "addMachine.step.heartbeat",
    consent: "addMachine.step.consent",
    "signed-in": "addMachine.step.signedIn",
    platform: "addMachine.step.platform",
    listed: "addMachine.step.listed",
    mesh: "addMachine.step.mesh",
    check: "addMachine.step.check",
  };
  return known[step];
}

/** The row's state for VoiceOver (the glyph carries it on screen). */
export function statusKey(row: ChecklistRow): string {
  if (row.status.kind === "pending") return "addMachine.status.pending";
  if (row.status.kind === "running") return "addMachine.status.running";
  return `addMachine.status.${row.status.state}`;
}

/** A button's title key; Add and Fix read as Adding… and Checking… while a run goes. */
export function buttonKey(action: AddMachineAction, phase: Phase): string {
  switch (action) {
    case "add":
      return phase === "running" ? "addMachine.adding" : "addMachine.add";
    case "fix":
      return phase === "running" ? "addMachine.checking" : "addMachine.fix";
    default:
      return `addMachine.${action}`;
  }
}

/** The checklist as plain text: host, name and one line per step with its fix (Copy Details). */
export function details(host: string, name: string, rows: readonly ChecklistRow[]): string {
  const lines = [`host: ${host}`, `name: ${name}`];
  for (const row of rows) {
    const state = row.status.kind === "done" ? row.status.state : row.status.kind;
    let line = `${row.step}: ${state}`;
    if (row.detail) line += ` - ${row.detail}`;
    if (row.fix) line += ` (fix: ${row.fix})`;
    lines.push(line);
  }
  return lines.join("\n");
}
