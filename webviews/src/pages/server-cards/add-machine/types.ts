// The wire of `cmux.addMachine.*` (CmuxNextServer/AddMachine/AddMachineCardProvider.swift).

/** The card's route on the server card page (`#/add-machine`). */
export const ADD_MACHINE_CARD = "add-machine";

export const AddMachineOps = {
  status: "cmux.addMachine.status",
  changes: "cmux.addMachine.changes",
  /** `{text}` → `{host, shortName}` or null: the field read as ssh takes it. */
  parse: "cmux.addMachine.parse",
  /** `{probe}` → the tailnet's machines, or null without Tailscale. */
  candidates: "cmux.addMachine.candidates",
  /** `{destination, name, peer?}`: Add and Try Again; the person's own click or key only. */
  add: "cmux.addMachine.add",
  /** `doctor --fix` for the checked machine; the person's own click or key only. */
  fix: "cmux.addMachine.fix",
  /** Stops the run in flight and forgets it (Cancel, Change Host). */
  cancel: "cmux.addMachine.cancel",
  /** Opens a workspace on the added machine. */
  openWorkspace: "cmux.addMachine.openWorkspace",
  /** `{text}`: Copy Details. */
  copy: "cmux.addMachine.copy",
} as const;

export type AddMachineMode =
  | { kind: "add" }
  | { kind: "check"; host: string; machineID: string }
  | { kind: "checkJoined"; id: string; name: string };

/** What opened the card: `seq` moves on every open, so the page resets its fields once per open. */
export interface AddMachineRequest {
  seq: number;
  mode: AddMachineMode;
  destination?: string;
  name?: string;
}

/** One thing a run did, in order; the page folds them into its checklist. */
export type RunEvent =
  /** A run starts: `joined` (a joined machine's check) starts with no rows, else the known steps. */
  | { kind: "start"; joined?: boolean }
  /** One stdout line of the CLI (a step or the report). */
  | { kind: "line"; line: string }
  /** The app installs its own cmux-tui build (the install row runs again). */
  | { kind: "install" }
  | { kind: "installEnd" }
  /** The run stopped without a report: why (the CLI's or the app's words, or empty). */
  | { kind: "stop"; detail: string };

export interface AddMachineRun {
  id: number;
  host: string;
  name: string;
  /** What Add sent: the field's text and a picked agent peer's name. Try Again sends them again. */
  destination?: string;
  peer?: string;
  events: RunEvent[];
  outcome: "running" | "ready" | "failed";
  /** The machine's app id once it is connected in the app (Open Workspace). */
  machineID?: string;
}

export interface AddMachineStatus {
  request: AddMachineRequest;
  run?: AddMachineRun;
}

export interface HostDestination {
  host: string;
  shortName: string;
}

/** One tailnet peer (`host candidates --json`), with what the app decides about it. */
export interface HostCandidate {
  id: string;
  name: string;
  os: string;
  online: boolean;
  alreadyPeer: boolean;
  peer?: string;
  sshOK?: boolean;
  inApp: boolean;
  /** What the field takes when the row is picked. */
  destination: string;
  /** Whether picking it can add it. */
  pickable: boolean;
}

export type Candidates = { kind: "loading" } | { kind: "loaded"; list: HostCandidate[] } | { kind: "unavailable" };
