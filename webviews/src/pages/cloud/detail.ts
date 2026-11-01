// Reads and changes for the selected machine's detail: its snapshots and this Mac's port forwards
// (the Files section is files.ts). Each section is read when the machine is selected and re-read
// after a change the owner confirmed (or after a native confirmation the user accepted). No polling.
// A reply for an older selection is dropped. A section whose op the owner does not serve yet is
// reported to the host (`unsupported`), which shows "Not available yet" for it. A native delete
// answered `cmux.cloud.not_found` found the item gone: the section is read again and no error shows.
// Snapshot create and delete are origin user at the server (a snapshot counts against the plan's
// saved limit): they run as native actions.
import { isPageError, type PageClient } from "../shared/pageClient";
import type { FilesView } from "./files";
import {
  ACTION_RUN,
  CloudOps,
  HostActions,
  isGone,
  isUnsupported,
  type ActionRunResult,
  type BrowserRoute,
  type BrowserTabOpenArgs,
  type CloudSnapshot,
  type PortForward,
  type PortListResult,
  type SnapshotListResult,
} from "./ops";

export type PortAction = "forward" | "close" | "browser";
export interface PendingPort {
  port: number;
  action: PortAction;
}

export interface MachineDetail {
  machine: string;
  loading: boolean;
  snapshots?: CloudSnapshot[];
  /** This Mac's forwards to the machine (`cloud.port.list`). */
  ports?: PortForward[];
  /** Actions stay pending through their host call and reconciliation, independently per port. */
  pendingPorts?: readonly PendingPort[];
  /** The last `cloud.browser.open` answer: its URL shows even when the host cannot open a tab. */
  browser?: BrowserRoute;
  /** The host refused the proxied tab for `browser` (typed error); nothing was opened. */
  browserRefused?: boolean;
  /** The Files section; read on demand (files.ts), never on selection. */
  files?: FilesView;
}

export type DetailSection = "snapshots" | "ports";

const SECTIONS: readonly DetailSection[] = ["snapshots", "ports"];

/** The read op behind each section. */
export const SECTION_OPS: Record<DetailSection, string> = {
  snapshots: CloudOps.snapshotList,
  ports: CloudOps.portList,
};

export interface DetailHost {
  get(): MachineDetail | undefined;
  set(detail: MachineDetail | undefined): void;
  fail(error: unknown): void;
  /** The owner does not serve `op` yet. */
  unsupported(op: string): void;
  /** A typed plan refusal (`plan_required`, `quota_exceeded`, `size_locked`) was shown; true = handled. */
  planRefused(error: unknown): boolean;
  /** A confirmed change that may move the plan's usage: the page reads the plan again. */
  usageChanged(): void;
  canChange(): boolean;
  key(): string;
}

export class DetailReader {
  private generation = 0;
  private portRevision = 0;
  private readonly portChanges = new Map<number, { revision: number; forward: PortForward | null }>();
  private readonly portActions = new Map<string, PendingPort & { machine: string }>();

  constructor(
    private readonly client: PageClient | null,
    private readonly host: DetailHost,
  ) {}

  async load(machine: string | undefined): Promise<void> {
    const generation = ++this.generation;
    this.portChanges.clear();
    if (!machine || !this.client) {
      this.portActions.clear();
      this.host.set(undefined);
      return;
    }
    const portRevision = this.portRevision;
    this.host.set({ machine, loading: true, pendingPorts: this.pendingPorts(machine) });
    const results = await Promise.allSettled(SECTIONS.map((section) => this.read(section, machine)));
    if (generation !== this.generation) return;
    // Keep what Browse, a forward or Open in browser wrote while the sections were read.
    const during = this.host.get();
    const kept =
      during?.machine === machine
        ? { files: during.files, browser: during.browser, browserRefused: during.browserRefused }
        : {};
    const detail: MachineDetail = { machine, loading: false, ...kept, pendingPorts: this.pendingPorts(machine) };
    let failed: unknown;
    SECTIONS.forEach((section, index) => {
      const result = results[index];
      if (result.status === "fulfilled") {
        if (section === "ports") {
          detail.ports = this.mergePorts(result.value as PortForward[], portRevision);
        } else Object.assign(detail, { [section]: result.value });
      } else if (isUnsupported(result.reason)) this.host.unsupported(SECTION_OPS[section]);
      else failed ??= result.reason;
    });
    this.host.set(detail);
    // One banner for the first real failure; the failed sections stay empty until they are read again.
    if (failed !== undefined) this.host.fail(failed);
  }

  async reload(section: DetailSection, changedPort?: number): Promise<void> {
    const current = this.host.get();
    if (!current || !this.client) return;
    const generation = this.generation;
    const portRevision = this.portRevision;
    try {
      const value = await this.read(section, current.machine);
      const latest = this.host.get();
      if (generation !== this.generation || !latest) return;
      const resolved = section === "ports" ? this.mergePorts(value as PortForward[], portRevision) : value;
      if (section === "ports" && changedPort !== undefined) {
        // A selection load can still be waiting on another section with an
        // older port list; preserve this authoritative mutation reconciliation.
        const forward = (resolved as PortForward[]).find((item) => item.port === changedPort) ?? null;
        this.portChanges.set(changedPort, { revision: ++this.portRevision, forward });
      }
      this.host.set({ ...latest, [section]: resolved });
    } catch (error) {
      if (generation === this.generation) this.reject(SECTION_OPS[section], error);
    }
  }

  /** Bumped by each selection: a reply started under an older one is dropped (files.ts too). */
  get epoch(): number {
    return this.generation;
  }

  /** `cloud.snapshot.create {machine, name?}`: counts against `max_saved`, so a person confirms it. */
  createSnapshot(machine: string, name?: string): Promise<void> {
    return this.native(CloudOps.snapshotCreate, { machine, ...(name ? { name } : {}) }, "snapshots");
  }

  /** `cloud.snapshot.delete {snapshot}`. */
  deleteSnapshot(snapshot: string): Promise<void> {
    return this.native(CloudOps.snapshotDelete, { snapshot }, "snapshots");
  }

  /** Forwards a port of the machine to 127.0.0.1 on this Mac; the answer names the local port. */
  forwardPort(machine: string, port: number): Promise<boolean> {
    return this.portAction(machine, port, "forward", async () => {
      const forward = await this.change<PortForward>(CloudOps.portForward, { machine, port });
      const latest = this.host.get();
      if (!forward?.localPort || latest?.machine !== machine) return false;
      this.portChanges.set(forward.port, { revision: ++this.portRevision, forward });
      const others = (latest.ports ?? []).filter((f) => f.port !== forward.port);
      this.host.set({ ...latest, ports: [...others, forward] });
      return true;
    });
  }

  closePort(machine: string, port: number): Promise<boolean> {
    return this.portAction(machine, port, "close", async () => {
      const closed = await this.change(CloudOps.portClose, { machine, port });
      if (closed === undefined) return false;
      this.portChanges.set(port, { revision: ++this.portRevision, forward: null });
      await this.reload("ports");
      return true;
    });
  }

  /**
   * Asks the server for a proxy route to the machine's localhost and shows its URL, then asks the
   * browser host for a CEF tab whose machine store carries the proxy (HostActions.browserTabOpen).
   * A host that does not serve the action yet shows "Not available yet". A typed refusal (CEF
   * unavailable, or WebKit refused the proxied configuration) shows `browserRefused`: the page never
   * retries in WebKit and never opens the URL without the proxy, which would load this Mac's
   * localhost. The URL stays visible in both cases.
   */
  openBrowser(machine: string, port: number, machineName: string): Promise<boolean> {
    return this.portAction(machine, port, "browser", async () => {
      const generation = this.generation;
      const route = await this.change<BrowserRoute>(CloudOps.browserOpen, { machine, port });
      const latest = this.host.get();
      if (!route?.url || latest?.machine !== machine) return false;
      this.host.set({ ...latest, browser: route, browserRefused: undefined });
      const args: BrowserTabOpenArgs = {
        url: route.url,
        incarnation: route.incarnation,
        generation: route.generation,
        machineStore: { machine: route.machine, machineName, proxy: route.proxy },
        engine: "cef",
      };
      try {
        const result = await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
          action: HostActions.browserTabOpen,
          args,
        });
        return result?.confirmed !== false;
      } catch (error) {
        if (generation !== this.generation) return false;
        if (isUnsupported(error) || (isPageError(error) && error.code === "cmux.protocol.transport")) {
          this.reject(HostActions.browserTabOpen, error);
        } else {
          const current = this.host.get();
          if (current?.machine === machine && current.browser === route)
            this.host.set({ ...current, browserRefused: true });
        }
        return false;
      }
    });
  }

  private mergePorts(ports: PortForward[], readRevision: number): PortForward[] {
    const merged = new Map(ports.map((forward) => [forward.port, forward]));
    for (const [port, { revision, forward }] of this.portChanges) {
      if (revision <= readRevision) continue;
      if (forward) merged.set(port, forward);
      else merged.delete(port);
    }
    return [...merged.values()];
  }

  private pendingPorts(machine: string): PendingPort[] {
    return [...this.portActions.values()].filter((pending) => pending.machine === machine);
  }

  /** Lock synchronously, including conflicting actions on the same port, before any host call. */
  private async portAction(
    machine: string,
    port: number,
    action: PortAction,
    run: () => Promise<boolean>,
  ): Promise<boolean> {
    const current = this.host.get();
    const key = JSON.stringify([machine, port]);
    if (!this.client || !this.host.canChange() || current?.machine !== machine || this.portActions.has(key))
      return false;
    const generation = this.generation;
    const pending = { machine, port, action };
    this.portActions.set(key, pending);
    this.host.set({ ...current, pendingPorts: this.pendingPorts(machine) });
    try {
      const accepted = await run();
      // A parked mutation may finish after A → B → A loaded a list from before
      // the effect. Its old answer is discarded, but the current selection must
      // reconcile with the host before the pending guard is released.
      if (generation !== this.generation && action !== "browser" && this.host.get()?.machine === machine)
        await this.reload("ports", port);
      return accepted && generation === this.generation;
    } finally {
      // A session reset can start a new action at the same key before the old call settles.
      if (this.portActions.get(key) === pending) {
        this.portActions.delete(key);
        const latest = this.host.get();
        if (latest?.machine === machine) this.host.set({ ...latest, pendingPorts: this.pendingPorts(machine) });
      }
    }
  }

  /** A change the host confirms natively; the page re-reads the section only after a yes. */
  async native(action: string, args: Record<string, unknown>, section?: DetailSection): Promise<void> {
    if (!this.client || !this.host.canChange()) return;
    try {
      const result = await this.client.call<ActionRunResult | null>(ACTION_RUN, {
        action,
        args: { ...args, idempotency_key: this.host.key() },
      });
      if (result?.confirmed === false) return;
      this.host.usageChanged();
      if (section) await this.reload(section);
    } catch (error) {
      // Already gone: the outcome the person asked for.
      if (isGone(error)) {
        if (section) await this.reload(section);
      } else if (!this.host.planRefused(error)) this.reject(action, error);
    }
  }

  /**
   * Sends one mutation with a new key; answers the owner's result (null when it answered nothing),
   * or undefined after a reject or when no change may be sent.
   */
  private async change<R = unknown>(op: string, params: Record<string, unknown>): Promise<R | null | undefined> {
    if (!this.client || !this.host.canChange()) return undefined;
    const generation = this.generation;
    try {
      const result = await this.client.call<R>(op, { ...params, idempotency_key: this.host.key() });
      return generation === this.generation ? (result ?? null) : undefined;
    } catch (error) {
      if (generation === this.generation) this.reject(op, error);
      return undefined;
    }
  }

  private reject(op: string, error: unknown): void {
    if (isUnsupported(error)) this.host.unsupported(op);
    else this.host.fail(error);
  }

  private read(section: DetailSection, machine: string): Promise<unknown> {
    const client = this.client!;
    switch (section) {
      case "snapshots":
        return client
          .call<SnapshotListResult>(CloudOps.snapshotList, { machine })
          .then((result): CloudSnapshot[] => result.snapshots);
      case "ports":
        return client
          .call<PortListResult>(CloudOps.portList, { machine })
          .then((result): PortForward[] => result.forwards);
    }
  }
}
