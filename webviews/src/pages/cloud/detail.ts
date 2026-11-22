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

export interface MachineDetail {
  machine: string;
  loading: boolean;
  snapshots?: CloudSnapshot[];
  /** This Mac's forwards to the machine (`cloud.port.list`). */
  ports?: PortForward[];
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

  constructor(
    private readonly client: PageClient | null,
    private readonly host: DetailHost,
  ) {}

  async load(machine: string | undefined): Promise<void> {
    const generation = ++this.generation;
    if (!machine || !this.client) {
      this.host.set(undefined);
      return;
    }
    this.host.set({ machine, loading: true });
    const results = await Promise.allSettled(SECTIONS.map((section) => this.read(section, machine)));
    if (generation !== this.generation) return;
    // Keep what Browse, a forward or Open in browser wrote while the sections were read.
    const during = this.host.get();
    const kept =
      during?.machine === machine
        ? { files: during.files, browser: during.browser, browserRefused: during.browserRefused }
        : {};
    const detail: MachineDetail = { machine, loading: false, ...kept };
    let failed: unknown;
    SECTIONS.forEach((section, index) => {
      const result = results[index];
      if (result.status === "fulfilled") Object.assign(detail, { [section]: result.value });
      else if (isUnsupported(result.reason)) this.host.unsupported(SECTION_OPS[section]);
      else failed ??= result.reason;
    });
    this.host.set(detail);
    // One banner for the first real failure; the failed sections stay empty until they are read again.
    if (failed !== undefined) this.host.fail(failed);
  }

  async reload(section: DetailSection): Promise<void> {
    const current = this.host.get();
    if (!current || !this.client) return;
    const generation = this.generation;
    try {
      const value = await this.read(section, current.machine);
      const latest = this.host.get();
      if (generation !== this.generation || !latest) return;
      this.host.set({ ...latest, [section]: value });
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
  async forwardPort(machine: string, port: number): Promise<void> {
    const forward = await this.change<PortForward>(CloudOps.portForward, { machine, port });
    const latest = this.host.get();
    if (!forward?.localPort || latest?.machine !== machine) return;
    const others = (latest.ports ?? []).filter((f) => f.port !== forward.port);
    this.host.set({ ...latest, ports: [...others, forward] });
  }

  async closePort(machine: string, port: number): Promise<void> {
    const closed = await this.change(CloudOps.portClose, { machine, port });
    if (closed !== undefined) await this.reload("ports");
  }

  /**
   * Asks the server for a proxy route to the machine's localhost and shows its URL, then asks the
   * browser host for a CEF tab whose machine store carries the proxy (HostActions.browserTabOpen).
   * A host that does not serve the action yet shows "Not available yet". A typed refusal (CEF
   * unavailable, or WebKit refused the proxied configuration) shows `browserRefused`: the page never
   * retries in WebKit and never opens the URL without the proxy, which would load this Mac's
   * localhost. The URL stays visible in both cases.
   */
  async openBrowser(machine: string, port: number, machineName: string): Promise<void> {
    const route = await this.change<BrowserRoute>(CloudOps.browserOpen, { machine, port });
    const latest = this.host.get();
    if (!route?.url || latest?.machine !== machine) return;
    this.host.set({ ...latest, browser: route, browserRefused: undefined });
    const args: BrowserTabOpenArgs = {
      url: route.url,
      machineStore: { machine: route.machine, machineName, proxy: route.proxy },
      engine: "cef",
    };
    try {
      await this.client!.call<ActionRunResult | null>(ACTION_RUN, { action: HostActions.browserTabOpen, args });
    } catch (error) {
      if (isUnsupported(error) || (isPageError(error) && error.code === "cmux.protocol.transport"))
        return this.reject(HostActions.browserTabOpen, error);
      const current = this.host.get();
      if (current?.machine === machine && current.browser === route)
        this.host.set({ ...current, browserRefused: true });
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
    try {
      return (await this.client.call<R>(op, { ...params, idempotency_key: this.host.key() })) ?? null;
    } catch (error) {
      this.reject(op, error);
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
