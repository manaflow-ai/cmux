/**
 * An in-memory stand-in for the upstream VM provider, behind the real upstream
 * client. It speaks the pinned provider API (upstream/openapi.json) for the
 * operations this service calls, records every request, and can be told to
 * fail an operation.
 */

export interface FakeVm {
  id: string;
  state: string;
  resources: { cpu: number; memory: number; storage: number };
  idleTimeoutSeconds: number | null;
  displayName: string | null;
  metadata: Record<string, string>;
  snapshotId: string | null;
}

export interface FakeSnapshot {
  readonly id: string;
  readonly sourceVmId: string;
  readonly autoDeleteSeconds: number | null;
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
  | "resize";

const VM_PATH = /^\/v5\/vms\/([^/]+)(?:\/(.+))?$/;
const SNAPSHOT_PATH = /^\/v5\/snapshots\/([^/]+)$/;

const vmBody = (vm: FakeVm) => ({
  id: vm.id,
  slug: `tenant-slug-${vm.id}`,
  snapshotId: vm.snapshotId ?? `sc-${vm.id}`,
  state: vm.state,
  resources: vm.resources,
  idleTimeoutSeconds: vm.idleTimeoutSeconds,
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
  const vms = new Map<string, FakeVm>();
  const snapshots = new Map<string, FakeSnapshot>();
  const files = new Map<string, Uint8Array>();
  const calls: UpstreamCall[] = [];
  const failures = new Map<UpstreamOperation, Array<{ readonly status: number; readonly body?: unknown }>>();
  /** Exec responses by command; the default echoes the command. */
  const execReplies = new Map<string, () => Response>();

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
    const vm = vmId === null ? undefined : vms.get(vmId);
    switch (operation) {
      case "list":
        return Response.json({ vms: [...vms.values()].map(vmBody) });
      case "create": {
        const body: unknown = await request.clone().json();
        const record = typeof body === "object" && body !== null ? body : {};
        const read = (key: string): unknown => (key in record ? Reflect.get(record, key) : undefined);
        const snapshotId = read("snapshotId");
        const base = typeof snapshotId === "string" ? BASE_IMAGES[snapshotId] : undefined;
        if (typeof snapshotId === "string" && base === undefined && !snapshots.has(snapshotId)) {
          return Response.json({ code: "BAD_REQUEST", message: "no such snapshot" }, { status: 400 });
        }
        const metadata = read("metadata");
        const created: FakeVm = {
          id: `vm-${crypto.randomUUID()}`,
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
        return Response.json(vmBody(created), { status: 201 });
      }
      case "get":
        return vm === undefined ? notFound() : Response.json(vmBody(vm));
      case "delete":
        if (vm === undefined) return notFound();
        vms.delete(vm.id);
        return new Response(null, { status: 204 });
      case "start":
        if (vm === undefined) return notFound();
        vm.state = "running";
        return Response.json(vmBody(vm));
      case "pause":
        if (vm === undefined) return notFound();
        if (vm.state !== "running") return conflict("the VM is not running");
        vm.state = "paused";
        return Response.json(vmBody(vm));
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
        snapshots.set(snapshot.id, snapshot);
        return Response.json({ snapshotId: snapshot.id, sourceVmId: vm.id, snapshot: { id: snapshot.id, createdAt: "2026-10-03T00:00:00Z", updatedAt: "2026-10-03T00:00:00Z" } });
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
        return Response.json(vmBody(vm));
      }
      case "exec": {
        if (vm === undefined) return notFound();
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
    }
  };

  const operationOf = (method: string, url: URL): { operation: UpstreamOperation; vmId: string | null } | null => {
    if (url.pathname === "/v5/vms") return method === "POST" ? { operation: "create", vmId: null } : { operation: "list", vmId: null };
    if (SNAPSHOT_PATH.test(url.pathname) && method === "DELETE") return { operation: "deleteSnapshot", vmId: null };
    const match = VM_PATH.exec(url.pathname);
    if (match?.[1] === undefined) return null;
    const vmId = decodeURIComponent(match[1]);
    const rest = match[2];
    if (rest === undefined) {
      if (method === "GET") return { operation: "get", vmId };
      if (method === "DELETE") return { operation: "delete", vmId };
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
    calls.push({ method: request.method, path: url.pathname, search: url.searchParams, json, bytes: raw });
    if (request.headers.get("authorization") !== `Bearer ${apiKey}`) {
      return Response.json({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 });
    }
    const route = operationOf(request.method, url);
    if (route === null) return Response.json({ code: "NOT_FOUND", message: "no route" }, { status: 404 });
    return handle(route.operation, request, url, route.vmId);
  };

  return {
    fetch,
    vms,
    snapshots,
    files,
    calls,
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
    /** Upstream calls of one operation kind, in order. */
    callsTo(method: string, pathPattern: RegExp) {
      return calls.filter((call) => call.method === method && pathPattern.test(call.path));
    },
  };
}

export type FakeUpstream = ReturnType<typeof makeFakeUpstream>;
