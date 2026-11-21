// l10n-allow-file: the browser dev loop's stand-in owner, not shipped UI.
// An in-memory server for the browser dev loop (`/server-cards/?mock#/server-panel`) and the page
// tests: one canned scenario, each intent applied and echoed on the next turn as the app's owner
// would (the switch, a new pairing code, Fix resolves its alert, Revoke drops the device).
import { offer, status, type ServerScenario } from "./fixtures";
import { ServerOps, type ServerIntent, type ServerStatus } from "./types";

export class MockServerOwner {
  private state: ServerStatus;
  private readonly listeners = new Set<() => void>();
  readonly received: { op: string; params: unknown }[] = [];

  constructor(name: ServerScenario = "healthyMac") {
    this.state = status(name);
  }

  handles(op: string): boolean {
    return op.startsWith("cmux.server.");
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  get current(): ServerStatus {
    return this.state;
  }

  async call(op: string, params: unknown): Promise<unknown> {
    this.received.push({ op, params });
    const p = (params ?? {}) as Record<string, unknown>;
    switch (op) {
      case ServerOps.status:
        return structuredClone(this.state);
      case ServerOps.send:
        this.apply(p as unknown as ServerIntent);
        return null;
      default:
        throw new Error(op);
    }
  }

  private apply(intent: ServerIntent) {
    const snapshot = this.state.snapshot ? structuredClone(this.state.snapshot) : undefined;
    if (!snapshot) return;
    switch (intent.kind) {
      case "setEnabled":
        snapshot.enabled = intent.on;
        for (const role of snapshot.roles) if (role.role !== "automations") role.state = intent.on ? "on" : "off";
        break;
      case "showPairingCode":
        if (snapshot.pairing.state !== "paired") snapshot.pairing = { state: "unpaired", offer: offer(Date.now()) };
        break;
      case "fixCheck": {
        const alert = snapshot.alerts.find((entry) => entry.check === intent.check && entry.resolvedAt === undefined);
        if (alert) alert.resolvedAt = Date.now();
        break;
      }
      case "revokeDevice":
        snapshot.devices = snapshot.devices.filter((device) => device.id !== intent.device);
        break;
    }
    queueMicrotask(() => this.update({ ...this.state, snapshot, lastReject: undefined }));
  }

  private update(next: ServerStatus) {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
