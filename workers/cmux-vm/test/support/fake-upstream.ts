/**
 * An in-memory stand-in for the upstream VM provider, behind the real upstream
 * client. It speaks the pinned provider API (upstream/openapi.json) for the
 * operations this service calls, records every request, and can be told to
 * fail an operation.
 */

export interface FakeVm {
  id: string;
  slug?: string | null;
  state: string;
  resources: { cpu: number; memory: number; storage: number };
  idleTimeoutSeconds: number | null;
  displayName: string | null;
  metadata: Record<string, string>;
  snapshotId: string | null;
  maxRunTotalSeconds?: number | null;
  maxRunSeconds?: number | null;
  autoDeleteSeconds?: number | null;
}

export interface FakeSnapshot {
  readonly id: string;
  readonly sourceVmId: string;
  readonly autoDeleteSeconds: number | null;
  readonly public?: boolean;
  readonly ttlSeconds?: number | null;
  readonly slug?: string;
  readonly displayName?: string;
}

/** One upstream call as the fake saw it. `json` is the parsed JSON body, if any. */
export interface UpstreamCall {
  readonly method: string;
  readonly path: string;
  readonly search: URLSearchParams;
  readonly json: unknown;
  readonly bytes: Uint8Array | null;
}

export type UpstreamOperation =
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
  | "deleteIdentity"
  | "updateVmAllowedLinuxUsers"
  | "listAccessTokens"
  | "revokeAccessToken"
  | "exists"
  | "mkdir"
  | "remove"
  | "beginUpload"
  | "uploadStatus"
  | "uploadChunk"
  | "commitUpload"
  | "abortUpload"
  | "updateSnapshot";

const VM_PATH = /^\/v5\/vms\/([^/]+)(?:\/(.+))?$/;
const SNAPSHOT_PATH = /^\/v5\/snapshots\/([^/]+)$/;
const UPLOAD_PATH = /^fs\/uploads\/([^/]+)(\/commit)?$/;

/** A provider upload session (fs/uploads). */
export interface FakeUpload {
  readonly id: string;
  readonly vmId: string;
  readonly path: string;
  readonly size: number;
  readonly sha256: string | null;
  received: Uint8Array<ArrayBuffer>;
}
const IDENTITY_PATH = /^\/v5\/identities\/([^/]+)(?:\/(permissions\/vm|tokens)(?:\/([^/]+))?)?$/;

/** A provider identity: its VM grants and access tokens (client sessions). */
interface FakeIdentity {
  readonly id: string;
  readonly grants: Array<{ readonly vmId: string; readonly allowedLinuxUsers: ReadonlyArray<string> | null }>;
  readonly tokens: Array<{ readonly id: string; readonly token: string }>;
}

const vmBody = (vm: FakeVm) => ({
  id: vm.id,
  slug: vm.slug ?? `tenant-slug-${vm.id}`,
  snapshotId: vm.snapshotId ?? `sc-${vm.id}`,
  state: vm.state,
  resources: vm.resources,
  idleTimeoutSeconds: vm.idleTimeoutSeconds,
  maxRunTotalSeconds: vm.maxRunTotalSeconds ?? null,
  ...(vm.maxRunSeconds === undefined ? {} : { maxRunSeconds: vm.maxRunSeconds }),
  ...(vm.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: vm.autoDeleteSeconds }),
  displayName: vm.displayName,
  metadata: { ...vm.metadata, cmuxTenant: "leak-check" },
  createdAt: "2026-10-01T00:00:00Z",
  updatedAt: "2026-10-02T00:00:00Z",
});

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
  const faults = { lostCreateResponses: 0, lostSnapshotResponses: 0 };
  const vms = new Map<string, FakeVm>();
  const snapshots = new Map<string, FakeSnapshot>();
  const tlsRules = new Map<string, Record<string, unknown>>();
  const files = new Map<string, Uint8Array>();
  const fileStats = new Map<string, Record<string, unknown>>();
  const calls: UpstreamCall[] = [];
  const identities = new Map<string, FakeIdentity>();
  const failures = new Map<UpstreamOperation, Array<{ readonly status: number; readonly body?: unknown }>>();
  /** Exec responses by command; the default echoes the command. */
  const execReplies = new Map<string, () => Response>();
  const resizeReplies = new Map<string, () => Response>();
  const updateReplies = new Map<string, () => Response>();
  /** Directories made with fs/mkdir, as `${vmId}\u0000${path}`. */
  const directories = new Set<string>();
  const uploads = new Map<string, FakeUpload>();

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
      case "updateVmAllowedLinuxUsers": {
        const grantVm = identityMatch?.[3] === undefined ? "" : decodeURIComponent(identityMatch[3]);
        const index = identity?.grants.findIndex((grant) => grant.vmId === grantVm) ?? -1;
        if (identity === undefined || index < 0) return notFound();
        const body: unknown = await request.json();
        const users: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "allowedLinuxUsers") : undefined;
        const allowedLinuxUsers = Array.isArray(users) ? users.filter((user): user is string => typeof user === "string") : null;
        identity.grants[index] = { vmId: grantVm, allowedLinuxUsers };
        return Response.json({ id: "perm-x", identityId: identity.id, vmId: grantVm, allowedLinuxUsers, grantedAt: "2026-10-21T00:00:00Z", grantedBy: "acct" });
      }
      case "listAccessTokens":
        return identity === undefined ? notFound() : Response.json(identity.tokens.map((token) => ({ id: token.id })));
      case "revokeAccessToken": {
        const tokenId = identityMatch?.[3] === undefined ? "" : decodeURIComponent(identityMatch[3]);
        const index = identity?.tokens.findIndex((token) => token.id === tokenId) ?? -1;
        if (identity === undefined || index < 0) return notFound();
        identity.tokens.splice(index, 1);
        return new Response(null, { status: 204 });
      }
      case "deleteIdentity": {
        if (identity === undefined) return notFound();
        identities.delete(identity.id);
        return new Response(null, { status: 204 });
      }
      case "list":
        return Response.json({ vms: [...vms.values()].map(vmBody) });
      case "create": {
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
          resources: { ...(base ?? DEFAULT_RESOURCES) },
          idleTimeoutSeconds: typeof read("idleTimeoutSeconds") === "number" ? Number(read("idleTimeoutSeconds")) : null,
          displayName: typeof read("displayName") === "string" ? String(read("displayName")) : null,
          metadata:
            typeof metadata === "object" && metadata !== null
              ? Object.fromEntries(Object.entries(metadata).map(([key, value]) => [key, String(value)]))
              : {},
          snapshotId: typeof snapshotId === "string" ? snapshotId : null,
        };
        vms.set(created.id, created);
        const tls = read("tls");
        const inline = typeof tls === "object" && tls !== null && "rules" in tls && Array.isArray(tls.rules) ? tls.rules : [];
        for (const value of inline) {
          if (typeof value !== "object" || value === null) continue;
          const id = `tls-${crypto.randomUUID()}`;
          tlsRules.set(id, { ...value, id, protocol: "http", source: { vmId: created.id } });
        }
        if (faults.lostCreateResponses > 0) { faults.lostCreateResponses--; throw new TypeError("lost provider create response"); }
        return Response.json(vmBody(created), { status: 201 });
      }
      case "get":
        return vm === undefined ? notFound() : Response.json(vmBody(vm));
      case "getSnapshot": {
        const id = decodeURIComponent(url.pathname.slice("/v5/snapshots/".length));
        const snapshot = snapshots.get(id) ?? [...snapshots.values()].find((s) => s.slug === id);
        return snapshot === undefined ? notFound() : Response.json({ ...snapshot, createdAt: "2026-10-03T00:00:00Z", updatedAt: "2026-10-03T00:00:00Z" });
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
        return new Response(null, { status: 204 });
      case "start":
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        vm.state = "running";
        return Response.json(vmBody(vm));
      case "pause":
        if (vm === undefined) return notFound();
        if (vm.state !== "running") return conflict("the VM is not running");
        vm.state = "paused";
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
        if (typeof body === "object" && body !== null) {
          if ("idleTimeoutSeconds" in body && typeof body.idleTimeoutSeconds === "number") vm.idleTimeoutSeconds = body.idleTimeoutSeconds;
          if ("maxRunSeconds" in body && typeof body.maxRunSeconds === "number") vm.maxRunSeconds = body.maxRunSeconds;
          if ("autoDeleteSeconds" in body && typeof body.autoDeleteSeconds === "number") vm.autoDeleteSeconds = body.autoDeleteSeconds;
          if ("displayName" in body && typeof body.displayName === "string") vm.displayName = body.displayName;
          if ("metadata" in body && typeof body.metadata === "object" && body.metadata !== null) {
            Object.assign(vm.metadata, Object.fromEntries(Object.entries(body.metadata).map(([key, value]) => [key, String(value)])));
          }
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
        if (reply !== undefined) return reply();
        if (vm.state !== "running") return conflict("the VM is not running");
        if (command === "poweroff") {
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
      case "updateSnapshot": {
        const match = SNAPSHOT_PATH.exec(url.pathname);
        const id = match?.[1] === undefined ? "" : decodeURIComponent(match[1]);
        const snapshot = snapshots.get(id);
        if (snapshot === undefined) return Response.json({ code: "NOT_FOUND", message: "no such snapshot" }, { status: 404 });
        const body: unknown = await request.clone().json();
        const read = (key: string): unknown => (typeof body === "object" && body !== null && key in body ? Reflect.get(body, key) : undefined);
        const next: FakeSnapshot = {
          ...snapshot,
          ...(typeof read("ttlSeconds") === "number" ? { ttlSeconds: Number(read("ttlSeconds")) < 0 ? null : Number(read("ttlSeconds")) } : {}),
          ...(typeof read("autoDeleteSeconds") === "number" ? { autoDeleteSeconds: Number(read("autoDeleteSeconds")) < 0 ? null : Number(read("autoDeleteSeconds")) } : {}),
          ...(typeof read("displayName") === "string" ? { displayName: String(read("displayName")) } : {}),
          ...(typeof read("slug") === "string" ? { slug: String(read("slug")) } : {}),
        };
        snapshots.set(id, next);
        return Response.json({ ...next, accountId: "acct-leak-check", createdAt: "2026-10-03T00:00:00Z", updatedAt: "2026-10-04T00:00:00Z" });
      }
      case "exists": {
        if (vm === undefined) return notFound();
        const path = url.searchParams.get("path") ?? "";
        const prefix = `${vm.id}\u0000${path}`;
        const exists = directories.has(prefix) || [...files.keys()].some((key) => key === prefix || key.startsWith(`${prefix}/`));
        return Response.json({ exists, vmId: vm.id });
      }
      case "mkdir": {
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        const body: unknown = await request.clone().json();
        const path = typeof body === "object" && body !== null && "path" in body ? String(body.path) : "";
        directories.add(fileKey(vm.id, path));
        return new Response(null, { status: 204 });
      }
      case "remove": {
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        const path = url.searchParams.get("path") ?? "";
        const key = fileKey(vm.id, path);
        const doomed = [...files.keys()].filter((name) => name === key || name.startsWith(`${key}/`));
        if (doomed.length === 0 && !directories.delete(key)) return Response.json({ code: "NOT_FOUND", message: "no such path" }, { status: 404 });
        for (const name of doomed) files.delete(name);
        return new Response(null, { status: 204 });
      }
      case "beginUpload": {
        if (vm === undefined) return notFound();
        if (vm.maxRunTotalSeconds === 0) return conflict("lifetime budget exhausted");
        const body: unknown = await request.clone().json();
        const read = (key: string): unknown => (typeof body === "object" && body !== null && key in body ? Reflect.get(body, key) : undefined);
        const size = Number(read("size"));
        if (!Number.isSafeInteger(size) || size < 0 || size > 16 * 1024 ** 3) return Response.json({ code: "BAD_REQUEST", message: "bad size" }, { status: 400 });
        const upload: FakeUpload = { id: `up-${crypto.randomUUID()}`, vmId: vm.id, path: String(read("path")), size, sha256: typeof read("sha256") === "string" ? String(read("sha256")) : null, received: new Uint8Array(0) };
        uploads.set(upload.id, upload);
        return Response.json({ uploadId: upload.id, path: upload.path, size, receivedBytes: 0, node: "host-leak-check" });
      }
      case "uploadStatus":
      case "uploadChunk":
      case "commitUpload":
      case "abortUpload": {
        if (vm === undefined) return notFound();
        const match = UPLOAD_PATH.exec(url.pathname.replace(/^\/v5\/vms\/[^/]+\//, ""));
        const upload = match?.[1] === undefined ? undefined : uploads.get(decodeURIComponent(match[1]));
        if (upload === undefined || upload.vmId !== vm.id) return Response.json({ code: "NOT_FOUND", message: "no such session" }, { status: 404 });
        const status = () => Response.json({ uploadId: upload.id, path: upload.path, size: upload.size, receivedBytes: upload.received.length });
        if (operation === "uploadStatus") return status();
        if (operation === "abortUpload") { uploads.delete(upload.id); return new Response(null, { status: 204 }); }
        if (operation === "uploadChunk") {
          const offset = Number(url.searchParams.get("offset"));
          const bytes = new Uint8Array(await request.clone().arrayBuffer());
          if (offset > upload.received.length) return conflict("gap");
          if (offset < upload.received.length) return status();
          if (offset + bytes.length > upload.size) return Response.json({ code: "BAD_REQUEST", message: "overrun" }, { status: 400 });
          const next = new Uint8Array(upload.received.length + bytes.length);
          next.set(upload.received);
          next.set(bytes, upload.received.length);
          upload.received = next;
          return status();
        }
        if (upload.received.length !== upload.size) return Response.json({ code: "BAD_REQUEST", message: "incomplete" }, { status: 400 });
        if (upload.sha256 !== null) {
          const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", upload.received)), (byte) => byte.toString(16).padStart(2, "0")).join("");
          if (digest !== upload.sha256) return Response.json({ code: "BAD_REQUEST", message: "sha256 mismatch" }, { status: 400 });
        }
        files.set(fileKey(vm.id, upload.path), upload.received);
        uploads.delete(upload.id);
        return new Response(null, { status: 204 });
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
    if (url.pathname === "/v5/tls" && method === "GET") return { operation: "listTlsRules", vmId: null };
    if (url.pathname.startsWith("/v5/tls/") && method === "PUT") return { operation: "replaceTlsRule", vmId: null };
    if (url.pathname === "/v5/vms") return method === "POST" ? { operation: "create", vmId: null } : { operation: "list", vmId: null };
    if (url.pathname === "/v5/identities" && method === "POST") return { operation: "createIdentity", vmId: null };
    const identity = IDENTITY_PATH.exec(url.pathname);
    if (identity !== null) {
      if (identity[2] === "permissions/vm" && identity[3] === undefined && method === "POST") return { operation: "grantVmPermission", vmId: null };
      if (identity[2] === "permissions/vm" && identity[3] !== undefined && method === "PATCH") return { operation: "updateVmAllowedLinuxUsers", vmId: null };
      if (identity[2] === "tokens" && identity[3] === undefined && method === "POST") return { operation: "createAccessToken", vmId: null };
      if (identity[2] === "tokens" && identity[3] === undefined && method === "GET") return { operation: "listAccessTokens", vmId: null };
      if (identity[2] === "tokens" && identity[3] !== undefined && method === "DELETE") return { operation: "revokeAccessToken", vmId: null };
      if (identity[2] === undefined && method === "DELETE") return { operation: "deleteIdentity", vmId: null };
      return null;
    }
    if (SNAPSHOT_PATH.test(url.pathname) && method === "DELETE") return { operation: "deleteSnapshot", vmId: null };
    if (SNAPSHOT_PATH.test(url.pathname) && method === "GET") return { operation: "getSnapshot", vmId: null };
    if (SNAPSHOT_PATH.test(url.pathname) && method === "PATCH") return { operation: "updateSnapshot", vmId: null };
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
      "GET fs/exists": "exists",
      "POST fs/mkdir": "mkdir",
      "DELETE fs/remove": "remove",
      "POST fs/uploads": "beginUpload",
    };
    const upload = UPLOAD_PATH.exec(rest);
    if (upload !== null) {
      if (upload[2] === "/commit") return method === "POST" ? { operation: "commitUpload", vmId } : null;
      if (method === "GET") return { operation: "uploadStatus", vmId };
      if (method === "PUT") return { operation: "uploadChunk", vmId };
      if (method === "DELETE") return { operation: "abortUpload", vmId };
      return null;
    }
    const operation = table[`${method} ${rest}`];
    return operation === undefined ? null : { operation, vmId };
  };

  const fetch = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const contentType = request.headers.get("content-type") ?? "";
    const raw = request.body === null ? null : new Uint8Array(await request.clone().arrayBuffer());
    let json: unknown = null;
    if (raw !== null && contentType.includes("application/json")) json = JSON.parse(new TextDecoder().decode(raw));
    calls.push({ method: request.method, path: url.pathname, search: url.searchParams, json, bytes: raw });
    if (request.headers.get("authorization") !== `Bearer ${apiKey}`) {
      return Response.json({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 });
    }
    const route = operationOf(request.method, url);
    if (route === null) return Response.json({ code: "NOT_FOUND", message: "no route" }, { status: 404 });
    return handle(route.operation, request, url, route.vmId);
  };

  return {
    faults,
    fetch,
    vms,
    snapshots,
    files,
    fileStats,
    calls,
    tlsRules,
    resizeReplies,
    updateReplies,
    directories,
    uploads,
    /** Makes the next `times` calls of `operation` answer `status`. */
    fail(operation: UpstreamOperation, status: number, times = 1, body?: unknown) {
      const queue = failures.get(operation) ?? [];
      for (let index = 0; index < times; index += 1) queue.push(body === undefined ? { status } : { status, body });
      failures.set(operation, queue);
    },
    /** Answers exec of exactly `command` with `reply()`. */
    replyToExec(command: string, reply: () => Response) {
      execReplies.set(command, reply);
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
    /** The provider token ids of the identity holding `token` (test inspection only; never in a cmux response). */
    identityTokenIds: (token: string) => [...identities.values()].find((id) => id.tokens.some((t) => t.token === token))?.tokens.map((t) => t.id) ?? [],
    /** Upstream calls of one operation kind, in order. */
    callsTo(method: string, pathPattern: RegExp) {
      return calls.filter((call) => call.method === method && pathPattern.test(call.path));
    },
  };
}

export type FakeUpstream = ReturnType<typeof makeFakeUpstream>;
