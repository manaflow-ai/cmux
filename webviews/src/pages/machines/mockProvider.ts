// l10n-allow-file: sample machine names for the dev loop and the gallery, not shipped UI.
// An in-memory Machines host for the browser dev loop (`/machines/?mock`) and the gallery: this Mac,
// one machine of each kind and state (MachineSectionRow.fixtures), and the hub's joined machines.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MachinesOps, type MachineRow, type MachinesSnapshot } from "./types";

export const thisMac: MachineRow = {
  id: "local",
  name: "This Mac",
  kind: "local",
  isLocal: true,
  isConnected: true,
  isConnecting: false,
};

const remote = (row: Partial<MachineRow> & Pick<MachineRow, "id" | "name" | "kind">): MachineRow => ({
  isLocal: false,
  isConnected: false,
  isConnecting: false,
  ...row,
});

/** The sample machines (`machines.section.fixture`), one of each kind and state. */
export const sampleRows: MachineRow[] = [
  thisMac,
  remote({ id: "fixture-cloud-1", name: "atlas-web", kind: "cloud", isConnected: true, health: "ok" }),
  remote({ id: "fixture-cloud-2", name: "gpu-box", kind: "cloud", isConnecting: true }),
  remote({ id: "fixture-cloud-3", name: "night-batch", kind: "cloud", serverState: "paused" }),
  remote({
    id: "fixture-ssh-1",
    name: "linux-box",
    kind: "ssh",
    isConnected: true,
    health: "warning",
    healthStep: "update",
  }),
  remote({ id: "fixture-ssh-2", name: "build-host", kind: "ssh" }),
  remote({ id: "fixture-server-1", name: "studio", kind: "server", isConnected: true }),
];

/** The hub's joined machines (`debug.joined_machines`): one linked to an SSH machine, two mesh-only. */
export const joinedRows: MachineRow[] = [
  remote({
    id: "ssh-lane",
    name: "lane-vm-3",
    kind: "ssh",
    isConnected: true,
    joined: { id: "m_lane", name: "lane-vm-3", state: "online", platform: "linux", mintedBy: "you@example.com" },
  }),
  remote({
    id: "joined:m_gpu",
    name: "gpu-west",
    kind: "joined",
    joined: { id: "m_gpu", name: "gpu-west", state: "offline", platform: "linux", mintedBy: "sam@example.com" },
  }),
  remote({
    id: "joined:m_mini",
    name: "studio-mini",
    kind: "joined",
    isConnected: true,
    health: "failing",
    healthStep: "heartbeat",
    joined: { id: "m_mini", name: "studio-mini", state: "online", platform: "macos", mintedBy: "you@example.com" },
  }),
];

export const sampleSnapshot: MachinesSnapshot = {
  rows: [...sampleRows, ...joinedRows],
  style: "compact",
  busy: [],
  failed: {},
};

export class MockMachinesProvider implements PageClient {
  private listeners = new Set<(snapshot: MachinesSnapshot) => void>();
  readonly calls: { op: string; params: unknown }[] = [];

  /** What `remove` answers (a test sets false for a refused Remove). */
  removeAnswer = true;
  /** Holds `remove`'s answer until `release` (a test reads the list while the host is still busy). */
  private hold?: Promise<void>;
  private release?: () => void;

  constructor(private snapshot: MachinesSnapshot = sampleSnapshot) {}

  /** Holds the next Remove until `finishRemove`. */
  holdRemove(): void {
    this.hold = new Promise((resolve) => (this.release = resolve));
  }

  finishRemove(): void {
    this.release?.();
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    switch (op) {
      case MachinesOps.snapshot:
        return this.snapshot as R;
      case MachinesOps.newWorkspace:
      case MachinesOps.addMachine:
        return { ran: true } as R;
      case MachinesOps.menu:
        return {} as R;
      case MachinesOps.remove:
        await this.hold;
        return { removed: this.removeAnswer } as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== MachinesOps.changes) throw pageError("cmux.op.unknown", stream);
    const listener = (snapshot: MachinesSnapshot) => onEvent(snapshot as E, 0);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** Replaces the snapshot and sends it, as the host does on a change. */
  push(snapshot: MachinesSnapshot): void {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener(snapshot);
  }
}
