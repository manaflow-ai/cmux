/**
 * An in-memory stand-in for the upstream VM provider, behind the real upstream
 * client. It speaks the pinned provider API (upstream/openapi.json) for the
 * operations this service calls, records every request, and can be told to
 * fail an operation.
 */

export interface FakeVm {
  vpcs?: ReadonlyArray<{ readonly vpc: string; readonly vpcId?: string | null; readonly ipv4?: string | null }>;
  id: string;
  slug?: string | null;
  state: string;
  resources: { cpu: number; memory: number; storage: number };
  idleTimeoutSeconds: number | null;
  displayName: string | null;
  metadata: Record<string, string>;
  snapshotId: string | null;
  maxRunTotalSeconds?: number | null;
  /** The provider's updatedAt; start and pause move it, as the provider's own does. */
  updatedAt?: string;
}

export interface FakeSnapshot {
  readonly id: string;
  readonly sourceVmId: string;
  readonly autoDeleteSeconds: number | null;
  readonly public?: boolean;
  readonly ttlSeconds?: number | null;
  readonly slug?: string;
  readonly displayName?: string;
  /** The size of the VM the snapshot was taken from: a VM created from it boots at this size (the default size without it). */
  readonly resources?: { readonly cpu: number; readonly memory: number; readonly storage: number };
}

/** One upstream call as the fake saw it. `json` is the parsed JSON body, if any. */
export interface UpstreamCall {
  readonly method: string;
  readonly path: string;
  readonly search: URLSearchParams;
  readonly json: unknown;
  readonly bytes: Uint8Array | null;
  /** The request's x-freestyle-background-after-secs, or null. */
  readonly backgroundAfter?: string | null;
}

export type UpstreamOperation =
  | "listFirewallRules"
  | "createFirewallRule"
  | "deleteFirewallRule"
  | "create"
  | "get"
  | "list"
  | "delete"
  | "start"
  | "pause"
  | "snapshot"
  | "deleteSnapshot"
  | "exec"
  | "read"
  | "write"
  | "dir"
  | "stat"
  | "resize"
  | "update"
  | "listTlsRules"
  | "replaceTlsRule"
  | "getSnapshot"
  | "createIdentity"
  | "grantVmPermission"
  | "createAccessToken"
  | "deleteIdentity";

const VM_PATH = /^\/v5\/vms\/([^/]+)(?:\/(.+))?$/;
const SNAPSHOT_PATH = /^\/v5\/snapshots\/([^/]+)$/;
const IDENTITY_PATH = /^\/v5\/identities\/([^/]+)(?:\/(permissions\/vm|tokens))?$/;

/** A provider identity: its VM grants and access tokens (client sessions). */
interface FakeIdentity {
  readonly id: string;
  readonly grants: Array<{ readonly vmId: string; readonly allowedLinuxUsers: ReadonlyArray<string> | null }>;
  readonly tokens: Array<{ readonly id: string; readonly token: string }>;
}

const vmBody = (vm: FakeVm) => ({
  ...(vm.vpcs === undefined ? {} : { vpcs: vm.vpcs }),
  id: vm.id,
  slug: vm.slug ?? `tenant-slug-${vm.id}`,
  snapshotId: vm.snapshotId ?? `sc-${vm.id}`,
  state: vm.state,
  resources: vm.resources,
  idleTimeoutSeconds: vm.idleTimeoutSeconds,
  maxRunTotalSeconds: vm.maxRunTotalSeconds ?? null,
  displayName: vm.displayName,
  metadata: { ...vm.metadata, cmuxTenant: "leak-check" },
  createdAt: "2026-10-01T00:00:00Z",
  updatedAt: vm.updatedAt ?? "2026-10-02T00:00:00Z",
});

let clock = 0;
const touch = (vm: FakeVm) => { clock += 1; vm.updatedAt = new Date(Date.UTC(2026, 9, 2) + clock * 1000).toISOString(); };

/** The provider's public base images and their sizes (upstream/sdk/vms/types.d.ts). */
const BASE_IMAGES: Readonly<Record<string, { cpu: number; memory: number; storage: number }>> = {
  "freestyle/ubuntu-sm": { cpu: 2, memory: 4096, storage: 16384 },
  "freestyle/ubuntu-lg": { cpu: 8, memory: 16384, storage: 65536 },
  "freestyle/ubuntu-xl": { cpu: 16, memory: 32768, storage: 131072 },
  "freestyle/ubuntu-2xl": { cpu: 32, memory: 65536, storage: 131072 },
};
const DEFAULT_RESOURCES = { cpu: 4, memory: 8192, storage: 32768 };

const notFound = () => Response.json({ code: "NOT_FOUND", message: "no such VM" }, { status: 404 });
const conflict = (message: string) => Response.json({ code: "CONFLICT", message }, { status: 409 });

export function makeFakeUpstream(apiKey: string) {
  const faults: {
    lostCreateResponses: number;
    lostSnapshotResponses: number;
    /** A create still joins the network it names, but its answer does not list the VM's networks. */
    hideCreateNetworks: boolean;
    /** The create answer lists the joined network under `vpcs` and a second, different list under `networks`. */
    splitCreateNetworks: boolean;
    /** The create answer's `debug` object (the provider's own phase timings), when set. */
    createDebug: unknown;
    /**
     * The next creates the provider is slow to make (a burst, staging 2026-11-27): held open without
     * x-freestyle-background-after-secs, the edge cuts the call (524) before the VM exists; with it, the create answers
     * 202 and its stored answer (the VM) follows `slowCreatePolls` pending polls.
     */
    slowCreates: number;
    slowCreatePolls: number;
  } = { slowCreates: 0, slowCreatePolls: 2, lostCreateResponses: 0, lostSnapshotResponses: 0, hideCreateNetworks: false, splitCreateNetworks: false, createDebug: undefined };
  /**
   * Private networks belong to mesh-fakes.ts, which sets this: a create that names a network joins it here. Answers the
   * VM's attachments, or null when the account has no such network (the create is then refused, as the provider's).
   */
  const hooks: {
    attachOnCreate: ((vmId: string, vpc: string) => NonNullable<FakeVm["vpcs"]> | null) | null;
    /** Runs before each create is handled (a provider that is slow, or hangs under load); an answer replaces the create's. */
    beforeCreate: (() => Promise<Response | null>) | null;
  } = { attachOnCreate: null, beforeCreate: null };
  const vms = new Map<string, FakeVm>();
  const snapshots = new Map<string, FakeSnapshot>();
  const tlsRules = new Map<string, Record<string, unknown>>();
  /** Public egress rules by id, with the VM each names (a create's inline rule has an empty source, as the provider's). */
  const firewallRules = new Map<string, { readonly vmId: string; readonly rule: Record<string, unknown> }>();
  /** Run one per rule list answered, in order, after the page is cut: a change between two pages. */
  const afterRuleList: Array<(() => void) | undefined> = [];
  const files = new Map<string, Uint8Array>();
  const fileStats = new Map<string, Record<string, unknown>>();
  const calls: UpstreamCall[] = [];
  const identities = new Map<string, FakeIdentity>();
  const failures = new Map<UpstreamOperation, Array<{ readonly status: number; readonly body?: unknown }>>();
  /** Exec responses by command; the default echoes the command. */
  const execReplies = new Map<string, (request: Request) => Response>();
  /**
   * Background requests (x-freestyle-background-after-secs): the answers a GET of
   * /v5/background-requests/{id} gives, in order; the last one repeats.
   */
  const backgroundRequests = new Map<string, Array<() => Response>>();
  const resizeReplies = new Map<string, () => Response>();
  const updateReplies = new Map<string, () => Response>();

  const takeFailure = (operation: UpstreamOperation): Response | null => {
    const queue = failures.get(operation);
    const next = queue?.shift();
    if (next === undefined) return null;
    return Response.json(next.body ?? { code: "FAILED", message: `${operation} failed` }, { status: next.status });
  };

  const fileKey = (vmId: string, path: string) => `${vmId}\u0000${path}`;

  const handle = async (operation: UpstreamOperation, request: Request, url: URL, vmId: string | null): Promise<Response> => {
    const failure = takeFailure(operation);
    if (failure !== null) return failure;
    const vm = vmId === null ? undefined : vms.get(vmId) ?? [...vms.values()].find((v) => v.slug === vmId);
    const identityMatch = IDENTITY_PATH.exec(url.pathname);
    const identity = identityMatch?.[1] === undefined ? undefined : identities.get(decodeURIComponent(identityMatch[1]));
    switch (operation) {
      case "createIdentity": {
        const created: FakeIdentity = { id: `id-${crypto.randomUUID()}`, grants: [], tokens: [] };
        identities.set(created.id, created);
        return Response.json({ id: created.id, managed: false });
      }
      case "grantVmPermission": {
        if (identity === undefined) return notFound();
        const body: unknown = await request.json();
        const grantVm: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "vmId") : undefined;
        const users: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "allowedLinuxUsers") : undefined;
        if (typeof grantVm !== "string" || !vms.has(grantVm)) return notFound();
        const allowedLinuxUsers = Array.isArray(users) ? users.filter((user): user is string => typeof user === "string") : null;
        identity.grants.push({ vmId: grantVm, allowedLinuxUsers });
        return Response.json({ id: `perm-${crypto.randomUUID()}`, identityId: identity.id, vmId: grantVm, allowedLinuxUsers, grantedAt: "2026-10-21T00:00:00Z", grantedBy: "acct" });
      }
      case "createAccessToken": {
        if (identity === undefined) return notFound();
        const token = { id: `tok-${crypto.randomUUID()}`, token: `fs_identity_${crypto.randomUUID()}` };
        identity.tokens.push(token);
        return Response.json(token);
      }
      case "deleteIdentity": {
        if (identity === undefined) return notFound();
        identities.delete(identity.id);
        return new Response(null, { status: 204 });
      }
      case "list":
        return Response.json({ vms: [...vms.values()].map(vmBody) });
      case "create": {
        const gated = hooks.beforeCreate === null ? null : await hooks.beforeCreate();
        if (gated !== null) return gated;
        const body: unknown = await request.clone().json();
        const record = typeof body === "object" && body !== null ? body : {};
        const read = (key: string): unknown => (key in record ? Reflect.get(record, key) : undefined);
        const snapshotId = read("snapshotId");
        const slug = read("slug");
        if (typeof slug === "string" && [...vms.values()].some((v) => v.slug === slug)) return conflict("slug already exists");
        const base = typeof snapshotId === "string" ? BASE_IMAGES[snapshotId] : undefined;
        if (typeof snapshotId === "string" && base === undefined && !snapshots.has(snapshotId)) {
          return Response.json({ code: "BAD_REQUEST", message: "no such snapshot" }, { status: 400 });
        }
        const metadata = read("metadata");
        const created: FakeVm = {
          id: `vm-${crypto.randomUUID()}`,
          slug: typeof slug === "string" ? slug : null,
          state: "starting",
          resources: { ...(base ?? (typeof snapshotId === "string" ? snapshots.get(snapshotId)?.resources : undefined) ?? DEFAULT_RESOURCES) },
          // Like the provider: its Vm schema has idleTimeoutSeconds minimum 0, so a create with -1 ("never pause")
          // reads back as null (production, 2026-11-04).
          idleTimeoutSeconds: typeof read("idleTimeoutSeconds") === "number" && Number(read("idleTimeoutSeconds")) >= 0 ? Number(read("idleTimeoutSeconds")) : null,
          displayName: typeof read("displayName") === "string" ? String(read("displayName")) : null,
          metadata:
            typeof metadata === "object" && metadata !== null
              ? Object.fromEntries(Object.entries(metadata).map(([key, value]) => [key, String(value)]))
              : {},
          snapshotId: typeof snapshotId === "string" ? snapshotId : null,
        };
        const wanted = read("networks");
        const first: unknown = Array.isArray(wanted) ? wanted[0] : undefined;
        const vpc: unknown = typeof first === "object" && first !== null ? Reflect.get(first, "vpc") : undefined;
        if (typeof vpc === "string") {
          const attachments = hooks.attachOnCreate?.(created.id, vpc) ?? null;
          if (attachments === null) return Response.json({ code: "NOT_FOUND", message: "no such network" }, { status: 404 });
          created.vpcs = attachments;
        }
        vms.set(created.id, created);
        const tls = read("tls");
        const inline = typeof tls === "object" && tls !== null && "rules" in tls && Array.isArray(tls.rules) ? tls.rules : [];
        for (const value of inline) {
          if (typeof value !== "object" || value === null) continue;
          const id = `tls-${crypto.randomUUID()}`;
          tlsRules.set(id, { ...value, id, protocol: "http", source: { vmId: created.id } });
        }
        const firewall = read("firewall");
        const inlineFirewall = typeof firewall === "object" && firewall !== null && "rules" in firewall && Array.isArray(firewall.rules) ? firewall.rules : [];
        for (const value of inlineFirewall) {
          if (typeof value !== "object" || value === null) continue;
          const id = `fwr-${crypto.randomUUID()}`;
          firewallRules.set(id, { vmId: created.id, rule: { ...value, id, createdAt: "2026-11-03T00:00:00Z", updatedAt: "2026-11-03T00:00:00Z" } });
        }
        if (faults.lostCreateResponses > 0) { faults.lostCreateResponses--; throw new TypeError("lost provider create response"); }
        const { vpcs: joined, ...answer } = vmBody(created);
        return Response.json({
          ...answer,
          ...(joined === undefined || faults.hideCreateNetworks ? {} : { vpcs: joined, networks: faults.splitCreateNetworks ? [...joined, { vpc: "vpc-some-other-network", ipv4: "10.99.0.2" }] : joined }),
          ...(faults.createDebug === undefined ? {} : { debug: faults.createDebug }),
        }, { status: 201 });
      }
      case "get":
        return vm === undefined ? notFound() : Response.json(vmBody(vm));
      case "getSnapshot": {
        const id = decodeURIComponent(url.pathname.slice("/v5/snapshots/".length));
        const snapshot = snapshots.get(id) ?? [...snapshots.values()].find((s) => s.slug === id);
        return snapshot === undefined ? notFound() : Response.json(snapshot);
      }
      case "listFirewallRules": {
        const forVm = url.searchParams.get("vmId");
        const offset = Number(url.searchParams.get("offset") ?? 0);
        const limit = Number(url.searchParams.get("limit") ?? 100);
        const listed = [...firewallRules.values()].filter((entry) => forVm === null || entry.vmId === forVm).map((entry) => entry.rule);
        const page = Response.json({ rules: listed.slice(offset, offset + limit), totalCount: listed.length });
        afterRuleList.shift()?.();
        return page;
      }
      case "createFirewallRule": {
        const body: unknown = await request.json();
        const source: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "source") : undefined;
        const ruleVm: unknown = typeof source === "object" && source !== null ? Reflect.get(source, "vmId") : undefined;
        if (typeof ruleVm !== "string" || !vms.has(ruleVm)) return notFound();
        const id = `fwr-${crypto.randomUUID()}`;
        const fields = typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
        const rule = { ...fields, id, createdAt: "2026-11-03T00:00:00Z", updatedAt: "2026-11-03T00:00:00Z" };
        firewallRules.set(id, { vmId: ruleVm, rule });
        return Response.json(rule);
      }
      case "deleteFirewallRule": {
        const id = decodeURIComponent(url.pathname.slice("/v5/firewall/rules/".length));
        if (!firewallRules.delete(id)) return notFound();
        return new Response(null, { status: 204 });
      }
      case "listTlsRules": {
        // Deliberately return unrelated/shared rules too: the client must verify exact source ownership.
        const offset = Number(url.searchParams.get("offset") ?? 0);
        const limit = Number(url.searchParams.get("limit") ?? 100);
        return Response.json({ rules: [...tlsRules.values()].slice(offset, offset + limit), totalCount: tlsRules.size });
      }
      case "replaceTlsRule": {
        const id = decodeURIComponent(url.pathname.slice("/v5/tls/".length));
        if (!tlsRules.has(id)) return notFound();
        const body: unknown = await request.json();
        if (typeof body !== "object" || body === null) return new Response(null, { status: 400 });
        const updated = { ...body, id };
        tlsRules.set(id, updated);
        return Response.json(updated);
      }
      case "delete":
        if (vm === undefined) return notFound();
        vms.delete(vm.id);
        for (const [id, entry] of firewallRules) if (entry.vmId === vm.id) firewallRules.delete(id);
        return new Response(null, { status: 204 });
      case "start":
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        vm.state = "running";
        touch(vm);
        return Response.json(vmBody(vm));
      case "pause":
        if (vm === undefined) return notFound();
        if (vm.state !== "running") return conflict("the VM is not running");
        vm.state = "paused";
        touch(vm);
        return Response.json(vmBody(vm));
      case "update": {
        if (vm === undefined) return notFound();
        const reply = updateReplies.get(vm.id);
        if (reply !== undefined) return reply();
        const body: unknown = await request.clone().json();
        if (typeof body === "object" && body !== null && "maxRunTotalSeconds" in body && body.maxRunTotalSeconds === 0) {
          vm.maxRunTotalSeconds = 0;
          if (vm.state !== "stopped") vm.state = "paused";
        }
        return Response.json(vmBody(vm));
      }
      case "snapshot": {
        if (vm === undefined) return notFound();
        if (vm.state !== "running" && vm.state !== "paused") return conflict("the VM is neither running nor paused");
        const body: unknown = await request.clone().json();
        const auto = typeof body === "object" && body !== null && "autoDeleteSeconds" in body ? body.autoDeleteSeconds : null;
        const snapshot: FakeSnapshot = {
          id: `sh-${crypto.randomUUID()}`,
          sourceVmId: vm.id,
          autoDeleteSeconds: typeof auto === "number" ? auto : null,
        };
        if (typeof body === "object" && body !== null) {
          Object.assign(snapshot, {
            ...("slug" in body && typeof body.slug === "string" ? { slug: body.slug } : {}),
            ...("displayName" in body && typeof body.displayName === "string" ? { displayName: body.displayName } : {}),
            ...("ttlSeconds" in body && typeof body.ttlSeconds === "number" ? { ttlSeconds: body.ttlSeconds } : {}),
          });
        }
        snapshots.set(snapshot.id, snapshot);
        if (faults.lostSnapshotResponses > 0) { faults.lostSnapshotResponses--; throw new TypeError("lost provider snapshot response"); }
        return Response.json({ snapshotId: snapshot.id, sourceVmId: vm.id, snapshot: { ...snapshot, public: false, createdAt: "2026-10-03T00:00:00Z", updatedAt: "2026-10-03T00:00:00Z" } });
      }
      case "deleteSnapshot": {
        const match = SNAPSHOT_PATH.exec(url.pathname);
        const id = match?.[1] === undefined ? "" : decodeURIComponent(match[1]);
        if (!snapshots.has(id)) return Response.json({ code: "NOT_FOUND", message: "no such snapshot" }, { status: 404 });
        snapshots.delete(id);
        return new Response(null, { status: 204 });
      }
      case "resize": {
        if (vm === undefined) return notFound();
        const body: unknown = await request.clone().json();
        const want = (key: "cpu" | "memory" | "storage"): number => {
          const value: unknown = typeof body === "object" && body !== null && key in body ? Reflect.get(body, key) : undefined;
          return typeof value === "number" ? value : vm.resources[key];
        };
        const next = { cpu: want("cpu"), memory: want("memory"), storage: want("storage") };
        if (next.cpu < vm.resources.cpu || next.memory < vm.resources.memory || next.storage < vm.resources.storage) {
          return Response.json({ code: "BAD_REQUEST", message: "grow only" }, { status: 400 });
        }
        vm.resources = next;
        return resizeReplies.get(vm.id)?.() ?? Response.json(vmBody(vm));
      }
      case "exec": {
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        const body: unknown = await request.clone().json();
        const command = typeof body === "object" && body !== null && "command" in body ? String(body.command) : "";
        const reply = execReplies.get(command);
        if (reply !== undefined) return reply(request);
        if (vm.state !== "running") return conflict("the VM is not running");
        if (command === "poweroff") {
          // As in the guest image: only root may power it off; the default user (ubuntu) is refused and the VM runs on.
          const user = typeof body === "object" && body !== null && "linuxUser" in body ? String(body.linuxUser) : "ubuntu";
          if (user !== "root") {
            return Response.json({ statusCode: 1, stdout: "", stderr: "Call to PowerOff failed: Interactive authentication required.\n", vmId: vm.id, node: "host-leak-check" });
          }
          vm.state = "stopped";
          return conflict("VM_NON_RESPONSIVE");
        }
        return Response.json({ statusCode: 0, stdout: `ran: ${command}\n`, stderr: "", vmId: vm.id, node: "host-leak-check" });
      }
      case "read": {
        if (vm === undefined) return notFound();
        const path = url.searchParams.get("path") ?? "";
        const bytes = files.get(fileKey(vm.id, path));
        if (bytes === undefined) return Response.json({ code: "NOT_FOUND", message: "no such path" }, { status: 404 });
        const range = request.headers.get("range");
        const match = range === null ? null : /^bytes=(\d+)-(\d+)$/.exec(range);
        if (match?.[1] !== undefined && match[2] !== undefined) {
          const start = Number(match[1]);
          const end = Math.min(Number(match[2]), bytes.length - 1);
          return new Response(bytes.slice(start, end + 1), {
            status: 206,
            headers: { "content-type": "application/octet-stream", "content-range": `bytes ${start}-${end}/${bytes.length}` },
          });
        }
        return new Response(bytes, { headers: { "content-type": "application/octet-stream", "x-upstream-node": vm.id } });
      }
      case "write": {
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        const path = url.searchParams.get("path") ?? "";
        files.set(fileKey(vm.id, path), new Uint8Array(await request.clone().arrayBuffer()));
        return new Response(null, { status: 204 });
      }
      case "dir": {
        if (vm === undefined) return notFound();
        const path = url.searchParams.get("path") ?? "";
        const prefix = path.endsWith("/") ? path : `${path}/`;
        const names = new Set<string>();
        for (const key of files.keys()) {
          const [owner, filePath] = key.split("\u0000");
          if (owner !== vm.id || filePath === undefined || !filePath.startsWith(prefix)) continue;
          const rest = filePath.slice(prefix.length);
          names.add(rest.includes("/") ? `${rest.split("/")[0]}/` : rest);
        }
        return Response.json({
          entries: [...names].sort().map((entry) =>
            entry.endsWith("/")
              ? { name: entry.slice(0, -1), kind: "directory", inode: 7 }
              : { name: entry, kind: "file", inode: 7 },
          ),
          vmId: vm.id,
        });
      }
      case "stat": {
        if (vm === undefined) return notFound();
        const path = url.searchParams.get("path") ?? "";
        const record = fileStats.get(fileKey(vm.id, path));
        if (record === undefined) return notFound();
        return Response.json(record);
      }
    }
  };

  const operationOf = (method: string, url: URL): { operation: UpstreamOperation; vmId: string | null } | null => {
    if (url.pathname === "/v5/firewall/rules" && method === "GET") return { operation: "listFirewallRules", vmId: null };
    if (url.pathname === "/v5/firewall/rules" && method === "POST") return { operation: "createFirewallRule", vmId: null };
    if (url.pathname.startsWith("/v5/firewall/rules/") && method === "DELETE") return { operation: "deleteFirewallRule", vmId: null };
    if (url.pathname === "/v5/tls" && method === "GET") return { operation: "listTlsRules", vmId: null };
    if (url.pathname.startsWith("/v5/tls/") && method === "PUT") return { operation: "replaceTlsRule", vmId: null };
    if (url.pathname === "/v5/vms") return method === "POST" ? { operation: "create", vmId: null } : { operation: "list", vmId: null };
    if (url.pathname === "/v5/identities" && method === "POST") return { operation: "createIdentity", vmId: null };
    const identity = IDENTITY_PATH.exec(url.pathname);
    if (identity !== null) {
      if (identity[2] === "permissions/vm" && method === "POST") return { operation: "grantVmPermission", vmId: null };
      if (identity[2] === "tokens" && method === "POST") return { operation: "createAccessToken", vmId: null };
      if (identity[2] === undefined && method === "DELETE") return { operation: "deleteIdentity", vmId: null };
      return null;
    }
    if (SNAPSHOT_PATH.test(url.pathname) && method === "DELETE") return { operation: "deleteSnapshot", vmId: null };
    if (SNAPSHOT_PATH.test(url.pathname) && method === "GET") return { operation: "getSnapshot", vmId: null };
    const match = VM_PATH.exec(url.pathname);
    if (match?.[1] === undefined) return null;
    const vmId = decodeURIComponent(match[1]);
    const rest = match[2];
    if (rest === undefined) {
      if (method === "GET") return { operation: "get", vmId };
      if (method === "DELETE") return { operation: "delete", vmId };
      if (method === "PATCH") return { operation: "update", vmId };
      return null;
    }
    const table: Record<string, UpstreamOperation> = {
      "POST start": "start",
      "POST pause": "pause",
      "POST snapshot": "snapshot",
      "POST resize": "resize",
      "POST exec-await": "exec",
      "GET fs/read": "read",
      "PUT fs/write": "write",
      "GET fs/dir": "dir",
      "GET fs/stat": "stat",
    };
    const operation = table[`${method} ${rest}`];
    return operation === undefined ? null : { operation, vmId };
  };

  const fetch = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const contentType = request.headers.get("content-type") ?? "";
    const raw = request.body === null ? null : new Uint8Array(await request.clone().arrayBuffer());
    let json: unknown = null;
    if (raw !== null && contentType.includes("application/json")) json = JSON.parse(new TextDecoder().decode(raw));
    calls.push({ method: request.method, path: url.pathname, search: url.searchParams, json, bytes: raw, backgroundAfter: request.headers.get("x-freestyle-background-after-secs") });
    if (request.headers.get("authorization") !== `Bearer ${apiKey}`) {
      return Response.json({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 });
    }
    const background = /^\/v5\/background-requests\/([^/]+)$/.exec(url.pathname);
    if (background !== null && request.method === "GET") {
      const answers = backgroundRequests.get(decodeURIComponent(background[1] ?? ""));
      if (answers === undefined) return Response.json({ code: "NOT_FOUND", message: "no such background request" }, { status: 404 });
      const next = answers.length > 1 ? answers.shift() : answers[0];
      return next === undefined ? Response.json({ code: "NOT_FOUND" }, { status: 404 }) : next();
    }
    const route = operationOf(request.method, url);
    if (route === null) return Response.json({ code: "NOT_FOUND", message: "no route" }, { status: 404 });
    if (route.operation === "create" && faults.slowCreates > 0) {
      faults.slowCreates--;
      if (request.headers.get("x-freestyle-background-after-secs") === null) return new Response("error code: 524", { status: 524 });
      const made = await handle(route.operation, request, url, route.vmId);
      const stored = await made.text(), status = made.status;
      const id = `bg-${crypto.randomUUID()}`;
      const accepted = () => Response.json({ requestId: id, status: "pending" }, { status: 202 });
      backgroundRequests.set(id, [...Array.from({ length: faults.slowCreatePolls }, () => accepted), () => new Response(stored, { status, headers: { "content-type": "application/json" } })]);
      return Response.json({ requestId: id }, { status: 202, headers: { "x-freestyle-background-request-id": id } });
    }
    return handle(route.operation, request, url, route.vmId);
  };

  return {
    faults,
    hooks,
    fetch,
    vms,
    snapshots,
    files,
    fileStats,
    calls,
    tlsRules,
    firewallRules,
    afterRuleList,
    resizeReplies,
    updateReplies,
    /** Makes the next `times` calls of `operation` answer `status`. */
    fail(operation: UpstreamOperation, status: number, times = 1, body?: unknown) {
      const queue = failures.get(operation) ?? [];
      for (let index = 0; index < times; index += 1) queue.push(body === undefined ? { status } : { status, body });
      failures.set(operation, queue);
    },
    /** Answers exec of exactly `command` with `reply(request)`. */
    replyToExec(command: string, reply: (request: Request) => Response) {
      execReplies.set(command, reply);
    },
    /**
     * Exec of `command` as the provider runs one that outlives its edge: held open without a
     * background header, the edge cuts it (524, as Freestyle's did at about 120 s); with
     * x-freestyle-background-after-secs it answers 202 with a request id, whose GET answers
     * `pending` 202s, then `result`.
     */
    longExec(command: string, result: () => Response, pending = 2) {
      const id = `bg-${crypto.randomUUID()}`;
      execReplies.set(command, (request) => {
        if (request.headers.get("x-freestyle-background-after-secs") === null) {
          return new Response("error code: 524", { status: 524 });
        }
        const accepted = () => Response.json({ requestId: id, status: "pending" }, { status: 202 });
        backgroundRequests.set(id, [...Array.from({ length: pending }, () => accepted), result]);
        return Response.json({ requestId: id }, { status: 202, headers: { "x-freestyle-background-request-id": id } });
      });
      return id;
    },
    /** Puts `answers` in front of background request `id`'s remaining answers. */
    backgroundAnswers(id: string, ...answers: Array<() => Response>) {
      backgroundRequests.set(id, [...answers, ...(backgroundRequests.get(id) ?? [])]);
    },
    addVm(state: string): FakeVm {
      const vm: FakeVm = {
        id: `vm-${crypto.randomUUID()}`,
        state,
        resources: { cpu: 4, memory: 8192, storage: 16384 },
        idleTimeoutSeconds: 300,
        displayName: null,
        metadata: {},
        snapshotId: null,
      };
      vms.set(vm.id, vm);
      return vm;
    },
    addSnapshot(sourceVmId: string): FakeSnapshot {
      const snapshot: FakeSnapshot = { id: `sh-${crypto.randomUUID()}`, sourceVmId, autoDeleteSeconds: null };
      snapshots.set(snapshot.id, snapshot);
      return snapshot;
    },
    /** How many provider identities exist (client sessions not revoked). */
    identityCount: () => identities.size,
    /** Whether an access token still works: its identity exists. */
    tokenValid: (token: string) => [...identities.values()].some((id) => id.tokens.some((t) => t.token === token)),
    /** The VM grants of the identity holding `token`. */
    identityGrants: (token: string) => [...identities.values()].find((id) => id.tokens.some((t) => t.token === token))?.grants ?? [],
    /** Upstream calls of one operation kind, in order. */
    callsTo(method: string, pathPattern: RegExp) {
      return calls.filter((call) => call.method === method && pathPattern.test(call.path));
    },
  };
}

export type FakeUpstream = ReturnType<typeof makeFakeUpstream>;
