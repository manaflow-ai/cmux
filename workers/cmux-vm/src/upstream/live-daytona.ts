import { Effect, Redacted } from "effect";
import type { UpstreamId } from "../lib/ids.ts";
import { UpstreamId as UpstreamIdSchema } from "../lib/ids.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import {
  UpstreamError,
  UpstreamVm,
  type FileRead,
  type SizeRequest,
  type UpstreamClientService,
} from "./client.ts";

export interface DaytonaClientConfig {
  readonly apiKey: Redacted.Redacted<string>;
  readonly apiUrl: string;
  readonly organizationId?: string;
  readonly fetch?: typeof globalThis.fetch;
  readonly environment: string;
}

interface DaytonaSandbox {
  readonly id: string;
  readonly name: string | undefined;
  readonly state: string | undefined;
  readonly cpu: number | undefined;
  readonly memory: number | undefined;
  readonly disk: number | undefined;
  readonly autoStopInterval: number | undefined;
  readonly autoDeleteInterval: number | undefined;
  readonly ttlMinutes: number | undefined;
  readonly createdAt: string | undefined;
  readonly updatedAt: string | undefined;
  readonly toolboxProxyUrl: string | undefined;
}

class DaytonaHttpFailure extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`Daytona returned HTTP ${status}`);
    this.status = status;
  }
}

const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_EXEC_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_VCPUS = 4;
const MAX_MEMORY_MIB = 8192;
const MAX_DISK_MIB = 10240;
const DEFAULT_EXEC_TIMEOUT_MS = 30_000;
const SNAPSHOT_TIMEOUT_MS = 120_000;
const SNAPSHOT_INITIAL_POLL_MS = 500;
const SNAPSHOT_MAX_POLL_MS = 5_000;
const SNAPSHOT_MAX_POLLS = 32;
const encoder = new TextEncoder();

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

const optionalString = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

const optionalNumber = (value: unknown): number | undefined => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

const upstreamId = (value: string): UpstreamId => UpstreamIdSchema.make(value);

const stateOf = (state: string | undefined): string => {
  switch (state) {
    case "started":
      return "running";
    case "paused":
      return "paused";
    case "pausing":
      return "pausing";
    case "stopped":
      return "stopped";
    case "destroyed":
      return "destroyed";
    case "archived":
      return "archived";
    case "starting":
    case "creating":
    case "restoring":
    case "resuming":
    case "pending_build":
    case "pulling_snapshot":
    case "building_snapshot":
      return "starting";
    default:
      return state ?? "unknown";
  }
};

const requiredDate = (value: string | undefined): string => (value === undefined ? new Date().toISOString() : value);

const vmFromSandbox = (sandbox: DaytonaSandbox): UpstreamVm => {
  if (sandbox.cpu === undefined || sandbox.memory === undefined || sandbox.disk === undefined) throw new Error("sandbox resources are missing");
  const autoStopInterval = sandbox.autoStopInterval ?? 0;
  const autoDeleteInterval = sandbox.autoDeleteInterval ?? -1;
  return {
    state: stateOf(sandbox.state),
    resources: { cpu: sandbox.cpu, memory: sandbox.memory * 1024, storage: sandbox.disk * 1024 },
    idleTimeoutSeconds: autoStopInterval === 0 ? -1 : autoStopInterval * 60,
    maxRunSeconds: null,
    autoDeleteSeconds: autoDeleteInterval < 0 ? -1 : autoDeleteInterval * 60,
    createdAt: requiredDate(sandbox.createdAt),
    updatedAt: requiredDate(sandbox.updatedAt),
  };
};

const decodeSandbox = (value: unknown): DaytonaSandbox => {
  if (!isRecord(value)) throw new Error("expected an object");
  const object = value;
  const id = optionalString(object.id);
  if (id === undefined) throw new Error("sandbox id is missing");
  return {
    id,
    name: optionalString(object.name),
    state: optionalString(object.state),
    cpu: optionalNumber(object.cpu),
    memory: optionalNumber(object.memory),
    disk: optionalNumber(object.disk),
    autoStopInterval: optionalNumber(object.autoStopInterval) ?? 0,
    autoDeleteInterval: optionalNumber(object.autoDeleteInterval) ?? -1,
    ttlMinutes: optionalNumber(object.ttlMinutes) ?? 0,
    createdAt: optionalString(object.createdAt),
    updatedAt: optionalString(object.updatedAt),
    toolboxProxyUrl: optionalString(object.toolboxProxyUrl),
  };
};

const jsonBody = (value: unknown): BodyInit => JSON.stringify(value);

const timeoutSignal = (timeoutMs: number): AbortSignal => AbortSignal.timeout(timeoutMs);

const multipartBody = (body: ReadableStream<Uint8Array>, length: number, filename: string) => {
  const boundary = `----cmux-daytona-${crypto.randomUUID()}`;
  const prefix = new TextEncoder().encode(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${filename.replaceAll(/["\\\r\n]/gu, "_")}"\nContent-Type: application/octet-stream\r\n\r\n`);
  const suffix = new TextEncoder().encode(`\r\n--${boundary}--\r\n`);
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      controller.enqueue(prefix);
      const reader = body.getReader();
      try {
        while (true) {
          const next = await reader.read();
          if (next.done) break;
          if (next.value !== undefined) controller.enqueue(next.value);
        }
        controller.enqueue(suffix);
        controller.close();
      } catch (error) {
        controller.error(error);
      }
    },
  });
  return { body: stream, length: prefix.byteLength + length + suffix.byteLength, headers: { "content-type": `multipart/form-data; boundary=${boundary}` } };
};

/** A fetch-backed Daytona adapter. The API key is only read in this module. */
export function makeDaytonaUpstreamClient(config: DaytonaClientConfig): UpstreamClientService {
  const base = new URL(config.apiUrl.endsWith("/") ? config.apiUrl : `${config.apiUrl}/`);
  const sendRequest: typeof fetch = config.fetch ?? ((request) => fetch(request));
  const toolboxOrigins = new Set<string>([base.origin]);
  if (!base.hostname.startsWith("proxy.", 0)) {
    const toolboxOrigin = new URL(base.toString());
    toolboxOrigin.hostname = `proxy.${base.hostname}`;
    toolboxOrigins.add(toolboxOrigin.origin);
  }

  const mainUrl = (path: string): URL => new URL(path.replace(/^\/+/, ""), base);
  const toolboxUrl = (proxy: string, sandboxId: string, path: string): URL | null => {
    try {
      const root = new URL(proxy.endsWith("/") ? proxy : `${proxy}/`);
      if (root.protocol !== "https:" || !toolboxOrigins.has(root.origin)) return null;
      return new URL(`${encodeURIComponent(sandboxId)}/${path.replace(/^\/+/, "")}`, root);
    } catch {
      return null;
    }
  };

  const send = (
    operation: string,
    url: URL,
    init: { readonly method: "GET" | "POST" | "PUT" | "DELETE"; readonly json?: unknown; readonly body?: ReadableStream<Uint8Array>; readonly length?: number; readonly headers?: Readonly<Record<string, string>>; readonly timeoutMs?: number },
    providerApi: boolean,
  ): Effect.Effect<Response, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const headers: Record<string, string> = { accept: "application/json", ...init.headers };
        headers.authorization = `Bearer ${Redacted.value(config.apiKey)}`;
        if (providerApi && config.organizationId !== undefined) headers["X-Daytona-Organization-ID"] = config.organizationId;
        let body: BodyInit | undefined;
        if (init.json !== undefined) {
          headers["content-type"] = "application/json";
          body = jsonBody(init.json);
        } else if (init.body !== undefined) {
          headers["content-type"] = headers["content-type"] ?? "application/octet-stream";
          const sized = new FixedLengthStream(init.length ?? 0);
          void init.body.pipeTo(sized.writable).catch(() => undefined);
          body = sized.readable;
        }
        const response = await sendRequest(
          new Request(url, {
            method: init.method,
            headers,
            ...(body === undefined ? {} : { body }),
            redirect: "manual",
            signal: timeoutSignal(init.timeoutMs ?? 120_000),
          }),
        );
        if (response.status < 200 || response.status > 299) {
          await response.body?.cancel();
          throw new DaytonaHttpFailure(response.status);
        }
        return response;
      },
      catch: (cause) => new UpstreamError({ operation, status: cause instanceof DaytonaHttpFailure ? cause.status : null }),
    });

  const readBoundedText = (operation: string, response: Response, maxBytes: number): Effect.Effect<{ readonly text: string; readonly truncated: boolean }, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        if (response.body === null) return { text: "", truncated: false };
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let bytes = 0;
        let text = "";
        while (true) {
          const next = await reader.read();
          if (next.done) return { text: `${text}${decoder.decode()}`, truncated: false };
          const chunk = next.value;
          if (chunk === undefined) return { text: `${text}${decoder.decode()}`, truncated: false };
          if (bytes + chunk.byteLength > maxBytes) {
            const keep = chunk.slice(0, Math.max(0, maxBytes - bytes));
            text += decoder.decode(keep, { stream: true });
            await reader.cancel();
            return { text, truncated: true };
          }
          bytes += chunk.byteLength;
          text += decoder.decode(chunk, { stream: true });
        }
      },
      catch: () => new UpstreamError({ operation, status: response.status }),
    });

  const readJson = (operation: string, response: Response, maxBytes = MAX_RESPONSE_BYTES): Effect.Effect<unknown, UpstreamError> =>
    readBoundedText(operation, response, maxBytes).pipe(
      Effect.flatMap(({ text, truncated }) => {
        if (truncated) return Effect.fail(new UpstreamError({ operation, status: 413 }));
        try {
          return Effect.succeed(JSON.parse(text));
        } catch {
          return Effect.fail(new UpstreamError({ operation, status: response.status }));
        }
      }),
    );

  const drain = (response: Response): Effect.Effect<void> => Effect.promise(async () => void (await response.body?.cancel()));

  const decodeSandboxResponse = (operation: string, response: Response): Effect.Effect<{ readonly sandbox: DaytonaSandbox; readonly vm: UpstreamVm }, UpstreamError> =>
    readJson(operation, response).pipe(
      Effect.flatMap((body) => {
        try {
          const sandbox = decodeSandbox(body);
          return Effect.succeed({ sandbox, vm: vmFromSandbox(sandbox) });
        } catch {
          return Effect.fail(new UpstreamError({ operation, status: response.status }));
        }
      }),
    );

  const getSandbox = (operation: string, id: UpstreamId) =>
    send(operation, mainUrl(`/sandbox/${encodeURIComponent(id)}`), { method: "GET" }, true).pipe(Effect.flatMap((response) => decodeSandboxResponse(operation, response)));

  const action = (operation: string, id: UpstreamId, actionName: "start" | "stop") =>
    send(operation, mainUrl(`/sandbox/${encodeURIComponent(id)}/${actionName}`), { method: "POST" }, true).pipe(
      Effect.flatMap((response) => decodeSandboxResponse(operation, response)),
      Effect.map(({ vm }) => vm),
    );

  const pauseAction = (operation: string, id: UpstreamId) =>
    send(operation, mainUrl(`/sandbox/${encodeURIComponent(id)}/pause`), { method: "POST" }, true).pipe(
      Effect.flatMap((response) => decodeSandboxResponse(operation, response)),
      Effect.map(({ vm }) => vm),
    );

  const deleteById = (operation: string, path: string): Effect.Effect<"deleted" | "gone", UpstreamError> =>
    send(operation, mainUrl(path), { method: "DELETE" }, true).pipe(
      Effect.flatMap(drain),
      Effect.as("deleted" as const),
      Effect.catchIf(
        (error) => error.status === 404,
        () => Effect.succeed("gone" as const),
      ),
    );

  const sizeIsValid = (size: SizeRequest | undefined): boolean =>
    size === undefined ||
    [size.vcpus, size.memoryMib, size.diskMib].every((value) => value === undefined || (Number.isFinite(value) && value > 0)) &&
      (size.vcpus === undefined || Number.isInteger(size.vcpus)) &&
      (size.memoryMib === undefined || size.memoryMib <= MAX_MEMORY_MIB) &&
      (size.diskMib === undefined || size.diskMib <= MAX_DISK_MIB) &&
      (size.vcpus === undefined || size.vcpus <= MAX_VCPUS);

  const sizeBody = (size: SizeRequest | undefined): Record<string, number> => {
    const body: Record<string, number> = {};
    if (size?.vcpus !== undefined) body.cpu = size.vcpus;
    if (size?.memoryMib !== undefined) body.memory = Math.ceil(size.memoryMib / 1024);
    if (size?.diskMib !== undefined) body.disk = Math.ceil(size.diskMib / 1024);
    return body;
  };

  const sourceSnapshot = (size: SizeRequest | undefined): string => {
    const fits = [
      ["daytona-small", 1, 1024, 3072],
      ["daytona-medium", 2, 4096, 8192],
      ["daytona-large", 4, 8192, 10240],
    ] as const;
    const eligible = fits.filter(([, cpu, memory, disk]) =>
      (size?.vcpus === undefined || cpu <= size.vcpus) &&
      (size?.memoryMib === undefined || memory <= size.memoryMib) &&
      (size?.diskMib === undefined || disk <= size.diskMib),
    );
    return (eligible.at(-1) ?? fits[0])[0];
  };

  const growVm = (id: UpstreamId, current: UpstreamVm, size: SizeRequest): Effect.Effect<UpstreamVm, UpstreamError> => {
    if (!sizeIsValid(size)) return Effect.fail(new UpstreamError({ operation: "resizeVm", status: 400 }));
    const body: Record<string, number> = {};
    if (size.vcpus !== undefined && size.vcpus > current.resources.cpu) body.cpu = size.vcpus;
    if (size.memoryMib !== undefined && size.memoryMib > current.resources.memory) body.memory = Math.ceil(size.memoryMib / 1024);
    if (size.diskMib !== undefined && size.diskMib > current.resources.storage) body.disk = Math.ceil(size.diskMib / 1024);
    if (Object.keys(body).length === 0) return Effect.succeed(current);
    const needsStop = body.disk !== undefined;
    const resize = send("resizeVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/resize`), { method: "POST", json: body }, true).pipe(
      Effect.flatMap((response) => decodeSandboxResponse("resizeVm", response)),
      Effect.map(({ vm }) => vm),
    );
    if (!needsStop) return resize;
    return Effect.gen(function* () {
      yield* action("resizeVm.stop", id, "stop");
      yield* waitForVmState("resizeVm.stop", id, "stopped").pipe(Effect.tapError(() => action("resizeVm.start", id, "start").pipe(Effect.ignore)));
      const resized = yield* resize.pipe(Effect.tapError(() => action("resizeVm.start", id, "start").pipe(Effect.ignore)));
      yield* action("resizeVm.start", id, "start");
      return yield* waitForVmState("resizeVm.start", id, "running").pipe(Effect.as(resized));
    });
  };

  const sandboxSnapshotName = (tenantId: string, cmuxId: string): string => `cmux-vm-${config.environment}-${tenantId}-${cmuxId}`.slice(0, 128);

  const idOf = <C, R>(owns: TenantOwnsResource<C, R>): Effect.Effect<UpstreamId> => Effect.sync(() => upstreamIdOf(owns));

  const waitForVmState = (operation: string, id: UpstreamId, expected: string): Effect.Effect<UpstreamVm, UpstreamError> => {
    const deadline = Date.now() + SNAPSHOT_TIMEOUT_MS;
    const poll = (attempt: number, delayMs: number): Effect.Effect<UpstreamVm, UpstreamError> =>
      getSandbox(operation, id).pipe(
        Effect.flatMap(({ vm }) =>
          vm.state === expected
            ? Effect.succeed(vm)
            : Date.now() >= deadline || attempt >= SNAPSHOT_MAX_POLLS
              ? Effect.fail(new UpstreamError({ operation, status: 504 }))
              : ["error", "build_failed", "destroyed", "archived"].includes(vm.state)
                ? Effect.fail(new UpstreamError({ operation, status: 409 }))
                : Effect.sleep(delayMs).pipe(Effect.zipRight(poll(attempt + 1, Math.min(SNAPSHOT_MAX_POLL_MS, delayMs * 2)))),
        ),
      );
    return poll(0, SNAPSHOT_INITIAL_POLL_MS);
  };

  const waitForSnapshot = (name: string): Effect.Effect<UpstreamId, UpstreamError> => {
    const deadline = Date.now() + SNAPSHOT_TIMEOUT_MS;
    let observedId: UpstreamId | null = null;
    const poll = (attempt: number, delayMs: number): Effect.Effect<UpstreamId, UpstreamError> =>
      send("snapshotVm", mainUrl(`/snapshots/${encodeURIComponent(name)}`), { method: "GET" }, true).pipe(
        Effect.flatMap((response) => readJson("snapshotVm", response)),
        Effect.flatMap((value) => {
          const record = isRecord(value) ? value : {};
          const id = typeof record.id === "string" ? record.id : null;
          if (id !== null) observedId = upstreamId(id);
          const state = typeof record.state === "string" ? record.state : null;
          if (id !== null && (state === "active" || state === "ready" || state === "completed")) return Effect.succeed(upstreamId(id));
          if (["error", "failed", "build_failed", "destroyed", "archived"].includes(state ?? "") || Date.now() >= deadline || attempt >= SNAPSHOT_MAX_POLLS) return Effect.fail(new UpstreamError({ operation: "snapshotVm", status: 502 }));
          return Effect.sleep(delayMs).pipe(Effect.zipRight(poll(attempt + 1, Math.min(SNAPSHOT_MAX_POLL_MS, delayMs * 2))));
        }),
        Effect.catchIf(
          (error) => error.status === 404 && Date.now() < deadline,
          () => Effect.sleep(delayMs).pipe(Effect.zipRight(poll(attempt + 1, Math.min(SNAPSHOT_MAX_POLL_MS, delayMs * 2)))),
        ),
      );
    return poll(0, SNAPSHOT_INITIAL_POLL_MS).pipe(
      Effect.tapError(() => observedId === null ? Effect.void : deleteById("discardSnapshot", `/snapshots/${encodeURIComponent(observedId)}`).pipe(Effect.ignore)),
    );
  };

  const decodeBase64 = (value: string): Uint8Array | null => {
    try {
      const binary = atob(value);
      return Uint8Array.from(binary, (character) => character.charCodeAt(0));
    } catch {
      return null;
    }
  };

  const execStream = (result: unknown): ReadableStream<Uint8Array> => {
    const record = isRecord(result) ? result : {};
    const raw = typeof record.result === "string" ? record.result : "";
    const marker = /^__CMUX_EXIT__(-?\d+)\n__CMUX_STDOUT__\n([A-Za-z0-9+/=]*)\n__CMUX_STDERR__\n([A-Za-z0-9+/=]*)\n?$/u.exec(raw);
    const stdoutBytes = marker === null ? null : decodeBase64(marker[2] ?? "");
    const stderrBytes = marker === null ? null : decodeBase64(marker[3] ?? "");
    const exitCode = marker === null ? (typeof record.exitCode === "number" && Number.isInteger(record.exitCode) ? record.exitCode : null) : Number(marker[1]);
    const stdout = stdoutBytes === null ? raw : new TextDecoder().decode(stdoutBytes);
    const stderr = stderrBytes === null ? (typeof record.stderr === "string" ? record.stderr : "") : new TextDecoder().decode(stderrBytes);
    const body = encoder.encode(JSON.stringify({ exitCode, stdout, stderr }));
    return new ReadableStream({
      start(controller) {
        controller.enqueue(body);
        controller.close();
      },
    });
  };

  const toolboxProxy = (operation: string, sandbox: DaytonaSandbox): Effect.Effect<string, UpstreamError> => {
    if (sandbox.toolboxProxyUrl !== undefined && toolboxUrl(sandbox.toolboxProxyUrl, sandbox.id, "/init") !== null) return Effect.succeed(sandbox.toolboxProxyUrl);
    return send(operation, mainUrl(`/sandbox/${encodeURIComponent(sandbox.id)}/toolbox-proxy-url`), { method: "GET" }, true).pipe(
      Effect.flatMap((response) => readJson(operation, response)),
      Effect.flatMap((value) => {
        const proxy = typeof value === "string" ? value : isRecord(value) && typeof value.url === "string" ? value.url : null;
        return proxy !== null && toolboxUrl(proxy, sandbox.id, "/init") !== null
          ? Effect.succeed(proxy)
          : Effect.fail(new UpstreamError({ operation, status: 502 }));
      }),
    );
  };

  const toolboxResponse = (operation: string, sandbox: DaytonaSandbox, path: string, init: Parameters<typeof send>[2]) =>
    toolboxProxy(operation, sandbox).pipe(
      Effect.flatMap((proxy) => {
        const url = toolboxUrl(proxy, sandbox.id, path);
        return url === null ? Effect.fail(new UpstreamError({ operation, status: 502 })) : send(operation, url, init, false);
      }),
    );

  const toolboxRequest = (operation: string, sandbox: DaytonaSandbox, path: string, init: Parameters<typeof send>[2], maxBytes = MAX_RESPONSE_BYTES) =>
    toolboxResponse(operation, sandbox, path, init).pipe(Effect.flatMap((response) => readJson(operation, response, maxBytes)));

  return {
    getVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => getSandbox("getVm", id)), Effect.map(({ vm }) => vm)),

    getVmForWrite: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => getSandbox("getVmForWrite", id)), Effect.map(({ vm }) => vm)),

    createVm: (caller, spec, { source }) =>
      Effect.gen(function* () {
        if (!sizeIsValid(spec.size)) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
        if (spec.maxRunSeconds !== undefined) return yield* Effect.fail(new UpstreamError({ operation: "createVm.maxRunSeconds", status: 400, unsupported: "Daytona cannot enforce maxRunSeconds without destroying the sandbox" }));
        if (spec.autoDeleteSeconds !== undefined) return yield* Effect.fail(new UpstreamError({ operation: "createVm.autoDeleteSeconds", status: 400, unsupported: "Daytona auto-delete semantics are not compatible with this API" }));
        const sourceId = source === undefined ? null : yield* idOf(source.owns);
        const requested = sizeBody(spec.size);
        if (sourceId !== null && Object.keys(requested).length > 0) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: 400, unsupported: "Daytona cannot resize a sandbox while creating it from a snapshot" }));
        const body: Record<string, unknown> = {
          name: `cmux-vm-${config.environment}-${caller.value.tenantId}-${spec.cmuxId}`.slice(0, 128),
          ...(sourceId !== null ? { snapshot: sourceId } : Object.keys(requested).length > 0 ? { buildInfo: { dockerfileContent: "FROM ubuntu:22.04\n" }, ...requested } : { snapshot: sourceSnapshot(spec.size) }),
          labels: { cmux_tenant: caller.value.tenantId, cmux_id: spec.cmuxId, cmux_env: spec.environment },
          autoStopInterval: spec.idleTimeoutSeconds < 0 ? 0 : Math.max(1, Math.ceil(spec.idleTimeoutSeconds / 60)),
        };
        return yield* send("createVm", mainUrl("/sandbox"), { method: "POST", json: body }, true).pipe(
          Effect.flatMap((response) => decodeSandboxResponse("createVm", response)),
          Effect.map(({ sandbox, vm }) => {
            const createdId = upstreamId(sandbox.id);
            const discard = deleteById("discardVm", `/sandbox/${encodeURIComponent(createdId)}`).pipe(Effect.ignore);
            return { upstreamId: createdId, vm, discard, grow: (size: SizeRequest) => growVm(createdId, vm, size) };
          }),
        );
      }),

    startVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => action("startVm", id, "start"))),

    /** Daytona's default container class has no memory-preserving pause; pause is a native stop. */
    pauseVm: (_vm, { owns }) => idOf(owns).pipe(
      Effect.flatMap((id) => pauseAction("pauseVm", id).pipe(Effect.catchIf(
        (error) => error.status === 404 || error.status === 405,
        () => Effect.fail(new UpstreamError({ operation: "pauseVm", status: 400, unsupported: "Daytona does not expose a native pause operation for this sandbox" })),
      ))),
    ),

    shutdownVm: (_vm, { owns }) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => send("shutdownVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/stop`), { method: "POST" }, true)),
        Effect.flatMap(drain),
      ),

    deleteVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => deleteById("deleteVm", `/sandbox/${encodeURIComponent(id)}`))),

    snapshotForFork: (caller, _vm, spec, { owns }) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("snapshotVm", id)),
        Effect.flatMap(({ sandbox, vm }) => {
          const wasRunning = vm.state === "running";
          const snapshotName = sandboxSnapshotName(caller.value.tenantId, spec.cmuxId);
          const id = upstreamId(sandbox.id);
          const stop = wasRunning ? action("snapshotVm.stop", id, "stop").pipe(Effect.zipRight(waitForVmState("snapshotVm.stop", id, "stopped"))) : Effect.succeed(vm);
          const take = stop.pipe(
            Effect.zipRight(send("snapshotVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/snapshot`), { method: "POST", json: { name: snapshotName, includeMemory: false } }, true)),
            Effect.flatMap((response) => drain(response)),
            Effect.zipRight(waitForSnapshot(snapshotName)),
            Effect.map((snapshotId) => ({ upstreamId: snapshotId, discard: deleteById("discardSnapshot", `/snapshots/${encodeURIComponent(snapshotId)}`).pipe(Effect.ignore) })),
          );
          return take.pipe(Effect.ensuring(wasRunning ? action("snapshotVm.start", id, "start").pipe(Effect.ignore) : Effect.void));
        }),
      ),

    deleteSnapshot: (_snapshot, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => deleteById("deleteSnapshot", `/snapshots/${encodeURIComponent(id)}`))),

    exec: (_vm, { owns }, spec) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("execVm", id)),
        Effect.flatMap(({ sandbox }) => {
          if (spec.linuxUser !== undefined) return Effect.fail(new UpstreamError({ operation: "execVm.linuxUser", status: 400, unsupported: "Daytona Toolbox execution cannot select a Linux user" }));
          const envs: Record<string, string> = { ...spec.env };
          envs.CMUX_DAYTONA_COMMAND = spec.command;
          const stdinPath = spec.stdinBase64 === undefined ? null : `/tmp/cmux-stdin-${crypto.randomUUID()}`;
          const command = `tmp=$(mktemp -d); (sh -c "$CMUX_DAYTONA_COMMAND"${stdinPath === null ? "" : ` < ${JSON.stringify(stdinPath)}`} >"$tmp/stdout" 2>"$tmp/stderr"); code=$?; printf '__CMUX_EXIT__%s\\n__CMUX_STDOUT__\\n' "$code"; base64 -w0 "$tmp/stdout"; printf '\\n__CMUX_STDERR__\\n'; base64 -w0 "$tmp/stderr"; rm -rf "$tmp"; exit 0`;
          const request: Record<string, unknown> = { command, ...(Object.keys(envs).length === 0 ? {} : { envs }), timeout: Math.max(1, Math.ceil((spec.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS) / 1000)) };
          const input = spec.stdinBase64 === undefined ? Effect.succeed<void>(undefined) : Effect.gen(function* () {
            const bytes = decodeBase64(spec.stdinBase64 ?? "");
            if (bytes === null || stdinPath === null) return yield* Effect.fail(new UpstreamError({ operation: "execVm", status: 400 }));
            const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(bytes); controller.close(); } });
            const multipart = multipartBody(body, bytes.byteLength, "stdin");
            yield* toolboxResponse("execVm.stdin", sandbox, `/files/upload-v2?path=${encodeURIComponent(stdinPath)}`, { method: "POST", body: multipart.body, length: multipart.length, headers: multipart.headers, timeoutMs: 900_000 }).pipe(Effect.flatMap(drain));
          });
          const cleanup = stdinPath === null ? Effect.void : toolboxResponse("execVm.stdin.cleanup", sandbox, `/files?path=${encodeURIComponent(stdinPath)}`, { method: "DELETE" }).pipe(Effect.flatMap(drain), Effect.ignore);
          return input.pipe(
            Effect.zipRight(toolboxRequest("execVm", sandbox, "/process/execute", { method: "POST", json: request, timeoutMs: (spec.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS) + 30_000 }, MAX_EXEC_RESPONSE_BYTES)),
            Effect.ensuring(cleanup),
            Effect.catchIf((error) => error.status === 408, () => Effect.succeed({ exitCode: null, result: "", stderr: "Command timed out" })),
            Effect.catchIf((error) => error.status === 413, () => Effect.succeed({ exitCode: null, result: "[output truncated at 8 MiB]", stderr: "" })),
          );
        }),
        Effect.map(execStream),
      ),

    readFile: (_vm, { owns }, path, range) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("readFile", id)),
        Effect.flatMap(({ sandbox }) => {
          const init = range === undefined ? { method: "GET" as const, timeoutMs: 900_000 } : { method: "GET" as const, headers: { range }, timeoutMs: 900_000 };
          return toolboxResponse("readFile", sandbox, `/files/download?path=${encodeURIComponent(path)}`, init).pipe(
            Effect.map((response): FileRead => ({
              status: response.status === 206 ? 206 : 200,
              contentRange: response.headers.get("content-range"),
              contentLength: response.headers.get("content-length"),
              body: response.body ?? new ReadableStream(),
            })),
          );
        }),
      ),

    writeFile: (_vm, { owns }, file) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("writeFile", id)),
        Effect.flatMap(({ sandbox }) => {
          const multipart = multipartBody(file.body, file.length, file.path.split("/").at(-1) ?? "file");
          return toolboxResponse("writeFile", sandbox, `/files/upload-v2?path=${encodeURIComponent(file.path)}`, { method: "POST", body: multipart.body, length: multipart.length, headers: multipart.headers, timeoutMs: 900_000 }).pipe(
            Effect.flatMap(drain),
            Effect.flatMap(() =>
              file.mode === undefined
                ? Effect.void
                : toolboxResponse("writeFileMode", sandbox, `/files/permissions?path=${encodeURIComponent(file.path)}&mode=${file.mode.toString(8)}`, { method: "POST" }).pipe(Effect.flatMap(drain)),
            ),
          );
        }),
      ),

    listFiles: (_vm, { owns }, path) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("listFiles", id)),
        Effect.flatMap(({ sandbox }) => toolboxRequest("listFiles", sandbox, `/files?path=${encodeURIComponent(path)}`, { method: "GET" })),
        Effect.flatMap((entries) => {
          if (!Array.isArray(entries)) return Effect.fail(new UpstreamError({ operation: "listFiles", status: null }));
          return Effect.succeed(
            entries.flatMap((entry) => {
              if (!isRecord(entry)) return [];
              const name = typeof entry.name === "string" ? entry.name : null;
              if (name === null) return [];
              return [{ name, kind: entry.isDir === true ? "directory" : "file" }];
            }),
          );
        }),
      ),
  } satisfies UpstreamClientService;
}
