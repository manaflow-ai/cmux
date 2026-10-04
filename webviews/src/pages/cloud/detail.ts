// Reads and changes for the selected machine's detail: stats, snapshots, publications, domains,
// networks and firewall rules. Each section is read when the machine is selected and re-read after
// a change the owner confirmed (or after a native confirmation the user accepted). No polling: the
// stats refresh only on selection or the Refresh button. A reply for an older selection is dropped.
import type { PageClient } from "../shared/pageClient";
import {
  ACTION_RUN,
  CloudOps,
  type ActionRunResult,
  type CloudDomain,
  type CloudNetwork,
  type CloudPublication,
  type CloudSnapshot,
  type FirewallRule,
  type MachineStats,
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
}

export type DetailSection = "stats" | "snapshots" | "publications" | "domains" | "networks" | "firewall";

const SECTIONS: readonly DetailSection[] = ["stats", "snapshots", "publications", "domains", "networks", "firewall"];

export interface DetailHost {
  get(): MachineDetail | undefined;
  set(detail: MachineDetail | undefined): void;
  fail(error: unknown): void;
  canChange(): boolean;
  key(): string;
}

export interface NewFirewallRule {
  action: "allow" | "deny";
  port?: number;
  protocol?: string;
  cidr?: string;
  description?: string;
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
    SECTIONS.forEach((section, index) => {
      const result = results[index];
      if (result.status === "fulfilled") Object.assign(detail, { [section]: result.value });
    });
    this.host.set(detail);
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
      this.host.fail(error);
    }
  }

  createSnapshot(machine: string, name?: string): Promise<void> {
    return this.mutate(CloudOps.snapshotCreate, { machine, ...(name ? { name } : {}) }, "snapshots");
  }

  restoreSnapshot(machine: string, snapshot: string): Promise<void> {
    return this.mutate(CloudOps.snapshotRestore, { machine, snapshot });
  }

  /** The new machine reaches the list through the watch stream. */
  forkSnapshot(machine: string, snapshot: string): Promise<void> {
    return this.mutate(CloudOps.snapshotFork, { machine, snapshot });
  }

  createPublication(machine: string, port: number): Promise<void> {
    return this.mutate(CloudOps.publicationCreate, { machine, port }, "publications");
  }

  verifyPublication(publication: string): Promise<void> {
    return this.mutate(CloudOps.publicationVerify, { publication }, "publications");
  }

  deletePublication(machine: string, publication: string): Promise<void> {
    return this.native(CloudOps.publicationDelete, { machine, publication }, "publications");
  }

  verifyDomain(domain: string): Promise<void> {
    return this.mutate(CloudOps.domainVerify, { domain }, "domains");
  }

  createFirewallRule(machine: string, rule: NewFirewallRule): Promise<void> {
    return this.native(CloudOps.firewallCreate, { machine, rule }, "firewall");
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
      this.host.fail(error);
    }
  }

  private async mutate(op: string, params: Record<string, unknown>, section?: DetailSection): Promise<void> {
    if (!this.client || !this.host.canChange()) return;
    try {
      await this.client.call(op, { ...params, idempotency_key: this.host.key() });
      if (section) await this.reload(section);
    } catch (error) {
      this.host.fail(error);
    }
  }

  private read(section: DetailSection, machine: string): Promise<unknown> {
    const client = this.client!;
    switch (section) {
      case "stats":
        return client.call<MachineStats>(CloudOps.machineStats, { machine });
      case "snapshots":
        return client.call<CloudSnapshot[]>(CloudOps.snapshotList, { machine });
      case "publications":
        return client.call<CloudPublication[]>(CloudOps.publicationList, { machine });
      case "domains":
        return client.call<CloudDomain[]>(CloudOps.domainList, {});
      case "networks":
        return client.call<CloudNetwork[]>(CloudOps.networkList, {});
      case "firewall":
        return client.call<FirewallRule[]>(CloudOps.firewallList, { machine });
    }
  }
}
