// Reads and changes for the selected machine's detail: stats, snapshots, publications, domains,
// networks, firewall rules and this Mac's port forwards (the Files section is files.ts). Each section is read when the machine is selected and re-read after
// a change the owner confirmed (or after a native confirmation the user accepted). No polling: the
// stats refresh only on selection or the Refresh button. A reply for an older selection is dropped.
// A section whose op the owner does not serve yet is reported to the host (`unsupported`), which
// shows "Not available yet" for it.
import { isPageError, type PageClient } from "../shared/pageClient";
import type { FilesView } from "./files";
import {
  ACTION_RUN,
  CloudOps,
  HostActions,
  type AccessMode,
  type ActionRunResult,
  type BrowserRoute,
  type BrowserTabOpenArgs,
  type CloudDomain,
  type CloudNetwork,
  type CloudPublication,
  type CloudSnapshot,
  type DomainListResult,
  type FirewallListResult,
  type FirewallRule,
  type MachineStats,
  type NetworkListResult,
  type NewFirewallRule,
  type PortForward,
  type PortListResult,
  type PublicationListResult,
  type SnapshotListResult,
  isUnsupported,
} from "./ops";

export interface MachineDetail {
  machine: string;
  loading: boolean;
  stats?: MachineStats;
  snapshots?: CloudSnapshot[];
  publications?: CloudPublication[];
  domains?: CloudDomain[];
  networks?: CloudNetwork[];
  firewall?: FirewallRule[];
  /** This Mac's forwards to the machine (`cloud.port.list`). */
  ports?: PortForward[];
  /** The last `cloud.browser.open` answer: its URL shows even when the host cannot open a tab. */
  browser?: BrowserRoute;
  /** The host refused the proxied tab for `browser` (typed error); nothing was opened. */
  browserRefused?: boolean;
  /** The Files section; read on demand (files.ts), never on selection. */
  files?: FilesView;
}

export type DetailSection = "stats" | "snapshots" | "publications" | "domains" | "networks" | "firewall" | "ports";

const SECTIONS: readonly DetailSection[] = [
  "stats",
  "snapshots",
  "publications",
  "domains",
  "networks",
  "firewall",
  "ports",
];

/** The read op behind each section. */
export const SECTION_OPS: Record<DetailSection, string> = {
  stats: CloudOps.machineStats,
  snapshots: CloudOps.snapshotList,
  publications: CloudOps.publicationList,
  domains: CloudOps.domainList,
  networks: CloudOps.networkList,
  firewall: CloudOps.firewallList,
  ports: CloudOps.portList,
};

export interface DetailHost {
  get(): MachineDetail | undefined;
  set(detail: MachineDetail | undefined): void;
  fail(error: unknown): void;
  /** The owner does not serve `op` yet. */
  unsupported(op: string): void;
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
    const detail: MachineDetail = { machine, loading: false };
    let failed: unknown;
    SECTIONS.forEach((section, index) => {
      const result = results[index];
      if (result.status === "fulfilled") Object.assign(detail, { [section]: result.value });
      else if (isUnsupported(result.reason)) this.host.unsupported(SECTION_OPS[section]);
      else failed ??= result.reason;
    });
    this.host.set(detail);
    // One banner for the first real failure; the failed sections stay empty until Refresh.
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
      this.reject(SECTION_OPS[section], error);
    }
  }

  createSnapshot(machine: string, name?: string): Promise<void> {
    return this.mutate(CloudOps.snapshotCreate, { machine, ...(name ? { name } : {}) }, "snapshots");
  }

  /**
   * Publishing a port on a host name is origin user (catalog `cloud.publication.create`): the host
   * confirms it natively. The page always sends the access mode it shows, so the confirmation names
   * the mode that applies; public access also sends `confirmPublic` (the Cloud API refuses it without).
   */
  createPublication(machine: string, port: number, accessMode: AccessMode): Promise<void> {
    const args = { machine, port, accessMode, ...(accessMode === "public" ? { confirmPublic: true } : {}) };
    return this.native(CloudOps.publicationCreate, args, "publications");
  }

  verifyPublication(publication: string): Promise<void> {
    return this.mutate(CloudOps.publicationVerify, { publication }, "publications");
  }

  deletePublication(publication: string): Promise<void> {
    return this.native(CloudOps.publicationDelete, { publication }, "publications");
  }

  /** `domain` is the host name (`cloud.domain.verify {domain}`). */
  verifyDomain(domain: string): Promise<void> {
    return this.mutate(CloudOps.domainVerify, { domain }, "domains");
  }

  createFirewallRule(rule: NewFirewallRule): Promise<void> {
    const args = {
      source: rule.source,
      destination: rule.destination,
      ...(rule.description ? { description: rule.description } : {}),
    };
    return this.native(CloudOps.firewallCreate, args, "firewall");
  }

  /**
   * Attaches this Mac's tunnel to a network. Origin user only: the host confirms natively and adds
   * the device fingerprint, which `cmux link` owns (README "Host gaps").
   */
  attachTunnel(network: string): Promise<void> {
    return this.native(CloudOps.tunnelAttach, { network });
  }

  /** A new WireGuard key for this Mac's tunnel. The host adds the fingerprint and the public key. */
  rotateTunnelKey(): Promise<void> {
    return this.native(CloudOps.tunnelRotateKey, {});
  }

  /** Forwards a port of the machine to 127.0.0.1 on this Mac; the answer names the local port. */
  async forwardPort(machine: string, port: number): Promise<void> {
    const forward = await this.change<PortForward>(CloudOps.portForward, { machine, port });
    const latest = this.host.get();
    if (!forward || latest?.machine !== machine) return;
    const others = (latest.ports ?? []).filter((f) => f.port !== forward.port);
    this.host.set({ ...latest, ports: [...others, forward] });
  }

  async closePort(machine: string, port: number): Promise<void> {
    const closed = await this.change(CloudOps.portClose, { machine, port });
    if (closed) await this.reload("ports");
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
    if (!route || latest?.machine !== machine) return;
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
      if (result?.confirmed !== false && section) await this.reload(section);
    } catch (error) {
      this.reject(action, error);
    }
  }

  private async mutate(op: string, params: Record<string, unknown>, section?: DetailSection): Promise<void> {
    const result = await this.change(op, params);
    if (result !== undefined && section) await this.reload(section);
  }

  /** Sends one mutation with a new key; answers the owner's result, or undefined after a reject. */
  private async change<R = unknown>(op: string, params: Record<string, unknown>): Promise<R | undefined> {
    if (!this.client || !this.host.canChange()) return undefined;
    try {
      return (await this.client.call<R>(op, { ...params, idempotency_key: this.host.key() })) ?? ({} as R);
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
      case "stats":
        return client.call<MachineStats>(CloudOps.machineStats, { machine });
      case "snapshots":
        return client
          .call<SnapshotListResult>(CloudOps.snapshotList, { machine })
          .then((result): CloudSnapshot[] => result.snapshots);
      case "publications":
        return client
          .call<PublicationListResult>(CloudOps.publicationList, { machine })
          .then((result): CloudPublication[] => result.publications);
      case "domains":
        return client.call<DomainListResult>(CloudOps.domainList, {}).then((result): CloudDomain[] => result.domains);
      case "networks":
        return client
          .call<NetworkListResult>(CloudOps.networkList, {})
          .then((result): CloudNetwork[] => result.networks);
      case "firewall":
        return client
          .call<FirewallListResult>(CloudOps.firewallList, { machine })
          .then((result): FirewallRule[] => result.rules);
      case "ports":
        return client
          .call<PortListResult>(CloudOps.portList, { machine })
          .then((result): PortForward[] => result.forwards);
    }
  }
}
