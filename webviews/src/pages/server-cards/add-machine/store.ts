// The Add Machine card's state owner: the host's runs (`cmux.addMachine.status`, read again on every
// change event) and what only the card holds: the host and Name fields, the tailnet list, the
// picked agent peer and Show Details. React reads it through `useSyncExternalStore`; a reply older
// than a newer read is dropped.
import { Checklist } from "./checklist";
import {
  buttons,
  defaultName,
  details,
  foldRun,
  peerTarget,
  phaseOf,
  runName,
  type AddMachineAction,
  type AddMachineButton,
  type Phase,
} from "./model";
import {
  AddMachineOps,
  type AddMachineRequest,
  type AddMachineStatus,
  type Candidates,
  type HostCandidate,
  type HostDestination,
} from "./types";

/** What the store needs of the page: its calls and streams, and the card's close. */
export interface AddMachineClient {
  call<T = unknown>(op: string, params?: unknown): Promise<T>;
  subscribe(stream: string, onEvent: (event: unknown) => void): Promise<() => void>;
}

export interface AddMachineSnapshot {
  status?: AddMachineStatus;
  destination: string;
  name: string;
  /** The field read as ssh takes it; null when it cannot. */
  parsed: HostDestination | null;
  /** The agent peer last picked from the list (already enrolled, not in the app yet). */
  picked?: HostCandidate;
  candidates: Candidates;
  showDetails: boolean;
  /** An action the host refused (a click that came too late, a host that went away). */
  failed: boolean;
  /** Add, Try Again or Fix was sent and the status after it is not read yet: a second press would
   * cancel the run it just started, so those buttons wait. */
  busy: boolean;
}

/** What the card shows, derived once per snapshot. */
export interface AddMachineView {
  phase: Phase;
  mode: AddMachineRequest["mode"];
  checklist: Checklist;
  installing: boolean;
  buttons: AddMachineButton[];
  defaultName: string;
  runName: string;
  runHost: string;
}

const EMPTY: AddMachineSnapshot = {
  destination: "",
  name: "",
  parsed: null,
  candidates: { kind: "loading" },
  showDetails: false,
  failed: false,
  busy: false,
};

/** The buttons that start a run (the host's add or fix replaces the run in flight). */
const STARTS_RUN: ReadonlySet<AddMachineAction> = new Set(["add", "tryAgain", "fix"]);

export function viewOf(snapshot: AddMachineSnapshot): AddMachineView {
  const run = snapshot.status?.run;
  const mode = snapshot.status?.request.mode ?? { kind: "add" };
  const phase = phaseOf(run);
  const { checklist, installing } = foldRun(run?.events ?? []);
  const peer = peerTarget(snapshot.picked, snapshot.destination, snapshot.parsed);
  const fallback = defaultName(peer, snapshot.parsed?.shortName);
  return {
    phase,
    mode,
    checklist,
    installing,
    buttons: buttons(phase, mode, snapshot.parsed !== null, run?.machineID).map((each) =>
      snapshot.busy && STARTS_RUN.has(each.action) ? { ...each, enabled: false } : each,
    ),
    defaultName: fallback,
    runName: run?.name ?? "",
    runHost: run?.host ?? "",
  };
}

export class AddMachineStore {
  private snapshot: AddMachineSnapshot = EMPTY;
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private parseRequest = 0;
  private candidatesRequest = 0;
  private seq?: number;
  /** While a pressed action that starts a run is in flight: the first status read issued after it
   * returned. Busy clears only when that read, or a later one, lands (a superseded read never does). */
  private busyUntil?: number;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: AddMachineClient | null,
    private readonly close: () => void = () => {},
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Follows the host's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const stop = await this.client.subscribe(AddMachineOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the card still reads on open and after each click.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
  }

  async refresh(): Promise<void> {
    if (!this.client) return;
    const id = ++this.request;
    let status: AddMachineStatus;
    try {
      status = await this.client.call<AddMachineStatus>(AddMachineOps.status, {});
    } catch {
      if (id === this.request)
        this.set({ ...this.snapshot, failed: true, busy: this.stillBusy(id) });
      return;
    }
    if (id !== this.request) return;
    if (status.request.seq !== this.seq) {
      this.busyUntil = undefined;
      return this.opened(status);
    }
    this.set({ ...this.snapshot, status, busy: this.stillBusy(id) });
  }

  /** Whether the action in flight still waits for its own status: a read issued before it returned
   * shows the state the press started from, so its buttons stay off. */
  private stillBusy(id: number): boolean {
    if (this.busyUntil === undefined) return this.snapshot.busy;
    if (id < this.busyUntil) return true;
    this.busyUntil = undefined;
    return false;
  }

  /** A new open: the fields as the opener filled them, or as the run in progress was added (a card
   * remounted over its run), and the list read again for Add Machine. */
  private opened(status: AddMachineStatus) {
    this.seq = status.request.seq;
    const run = status.request.mode.kind === "add" ? status.run : undefined;
    const destination = (run ? run.destination : undefined) ?? status.request.destination ?? "";
    const name = run?.destination !== undefined ? run.name : (status.request.name ?? "");
    this.set({ ...EMPTY, status, destination, name });
    void this.parse(destination);
    if (status.request.mode.kind === "add" && !status.run) void this.loadCandidates();
  }

  setDestination(text: string): void {
    // The old reading goes with the old text: Add waits for this text's parse.
    this.set({ ...this.snapshot, destination: text, parsed: null });
    void this.parse(text);
  }

  setName(text: string): void {
    this.set({ ...this.snapshot, name: text });
  }

  toggleDetails(): void {
    this.set({ ...this.snapshot, showDetails: !this.snapshot.showDetails });
  }

  /** A candidate row was clicked: its name goes in the field. Nothing runs until Add is pressed,
   * an agent peer included (the person's click is the trust step). */
  pick(candidate: HostCandidate): void {
    if (!candidate.pickable || phaseOf(this.snapshot.status?.run) !== "pick") return;
    this.set({
      ...this.snapshot,
      destination: candidate.destination,
      parsed: null,
      picked: candidate.alreadyPeer ? candidate : undefined,
    });
    void this.parse(candidate.destination);
  }

  /** Runs a card button (its click or its key). */
  async perform(action: AddMachineAction): Promise<void> {
    if (!this.client) return;
    const view = viewOf(this.snapshot);
    const enabled = view.buttons.find((each) => each.action === action)?.enabled ?? false;
    if (!enabled) return;
    const starts = STARTS_RUN.has(action);
    if (starts) this.set({ ...this.snapshot, busy: true });
    try {
      switch (action) {
        case "add":
          await this.add();
          break;
        case "tryAgain":
          await this.retry();
          break;
        case "changeHost":
          await this.client.call(AddMachineOps.cancel, {});
          // The next Add enrolls the field's host; a peer picked for the failed run goes with it.
          this.set({ ...this.snapshot, picked: undefined });
          void this.loadCandidates();
          break;
        case "fix":
          await this.client.call(AddMachineOps.fix, {});
          break;
        case "openWorkspace":
          await this.client.call(AddMachineOps.openWorkspace, {});
          this.close();
          return;
        case "copyDetails":
          await this.client.call(AddMachineOps.copy, {
            text: details(view.runHost, view.runName, view.checklist.rows),
          });
          return;
        case "done":
          this.close();
          return;
        case "cancel":
          await this.client.call(AddMachineOps.cancel, {});
          this.close();
          return;
      }
    } catch {
      this.busyUntil = undefined;
      this.set({ ...this.snapshot, failed: true, busy: false });
      return;
    }
    // Busy clears with the first status read issued from here on (this one, or a change event's
    // that supersedes it), never on a reply that predates the press's effect.
    if (starts) this.busyUntil = this.request + 1;
    await this.refresh();
  }

  /** The button Escape presses (Cancel or Done; the panel's Escape too); with none, the card closes. */
  async escape(): Promise<void> {
    const button = viewOf(this.snapshot).buttons.find((each) => each.key === "escape");
    if (button) return this.perform(button.action);
    this.close();
  }

  /** The button Return presses. */
  submit(): Promise<void> {
    const button = viewOf(this.snapshot).buttons.find((each) => each.key === "return");
    return button ? this.perform(button.action) : Promise.resolve();
  }

  /** Try Again sends the failed run's own request; a host without it (an older app) runs the fields. */
  private async retry() {
    const run = this.snapshot.status?.run;
    if (run?.destination === undefined) return this.add();
    await this.client!.call(AddMachineOps.add, {
      destination: run.destination,
      name: run.name,
      ...(run.peer !== undefined ? { peer: run.peer } : {}),
    });
  }

  private async add() {
    // Add runs the fields as they are.
    const { destination, name, picked, parsed } = this.snapshot;
    const peer = peerTarget(picked, destination, parsed);
    await this.client!.call(AddMachineOps.add, {
      destination,
      name: runName(name, viewOf(this.snapshot).defaultName),
      ...(peer ? { peer: peer.peer ?? "" } : {}),
    });
  }

  private async parse(text: string) {
    if (!this.client) return;
    const id = ++this.parseRequest;
    let parsed: HostDestination | null = null;
    try {
      parsed =
        text.trim() === ""
          ? null
          : await this.client.call<HostDestination | null>(AddMachineOps.parse, { text });
    } catch {
      parsed = null;
    }
    if (id === this.parseRequest && this.snapshot.destination === text)
      this.set({ ...this.snapshot, parsed });
  }

  /** The plain list first (one local tailscale call), then the ssh probe of the person's own
   * machines; a probe that fails or times out leaves the unprobed list showing. */
  private async loadCandidates() {
    if (!this.client) return;
    const id = ++this.candidatesRequest;
    this.set({ ...this.snapshot, candidates: { kind: "loading" } });
    const read = async (probe: boolean) => {
      try {
        return await this.client!.call<HostCandidate[] | null>(AddMachineOps.candidates, { probe });
      } catch {
        return null;
      }
    };
    const list = await read(false);
    if (id !== this.candidatesRequest) return;
    this.set({
      ...this.snapshot,
      candidates: list ? { kind: "loaded", list } : { kind: "unavailable" },
    });
    if (!list) return;
    const probed = await read(true);
    if (id !== this.candidatesRequest || !probed) return;
    this.set({ ...this.snapshot, candidates: { kind: "loaded", list: probed } });
  }

  private set(snapshot: AddMachineSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
