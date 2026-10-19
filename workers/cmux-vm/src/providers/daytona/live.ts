import { Effect, Redacted } from "effect";
import type { UpstreamId } from "../../lib/ids.ts";
import { UpstreamId as UpstreamIdSchema } from "../../lib/ids.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../../proofs/tenant-owns-resource.ts";
import {
  UpstreamError,
  UpstreamVm,
  type FileRead,
  type SizeRequest,
  type UpstreamClientService,
} from "../../upstream/client.ts";

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

const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_VCPUS = 4;
const MAX_MEMORY_MIB = 8192;
const MAX_DISK_MIB = 10240;
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
    case "destroyed":
    case "archived":
      return "stopped";
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
  return {
    state: stateOf(sandbox.state),
    resources: { cpu: sandbox.cpu, memory: sandbox.memory * 1024, storage: sandbox.disk * 1024 },
    idleTimeoutSeconds: sandbox.autoStopInterval === undefined ? null : sandbox.autoStopInterval === 0 ? -1 : sandbox.autoStopInterval * 60,
    maxRunSeconds: sandbox.ttlMinutes === undefined ? null : sandbox.ttlMinutes === 0 ? -1 : sandbox.ttlMinutes * 60,
    autoDeleteSeconds:
      sandbox.autoDeleteInterval === undefined ? null : sandbox.autoDeleteInterval < 0 ? -1 : sandbox.autoDeleteInterval * 60,
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
    autoStopInterval: optionalNumber(object.autoStopInterval),
    autoDeleteInterval: optionalNumber(object.autoDeleteInterval),
    ttlMinutes: optionalNumber(object.ttlMinutes),
    createdAt: optionalString(object.createdAt),
    updatedAt: optionalString(object.updatedAt),
    toolboxProxyUrl: optionalString(object.toolboxProxyUrl),
  };
};

const jsonBody = (value: unknown): BodyInit => JSON.stringify(value);

const timeoutSignal = (timeoutMs: number): AbortSignal => AbortSignal.timeout(timeoutMs);

/** A fetch-backed Daytona adapter. The API key is only read in this module. */
export function makeDaytonaUpstreamClient(config: DaytonaClientConfig): UpstreamClientService {
  const base = new URL(config.apiUrl.endsWith("/") ? config.apiUrl : `${config.apiUrl}/`);
  const sendRequest: typeof globalThis.fetch = config.fetch ?? globalThis.fetch;

  const mainUrl = (path: string): URL => new URL(path.replace(/^\/+/, ""), base);
  const toolboxUrl = (proxy: string, sandboxId: string, path: string): URL => {
    const root = new URL(proxy.endsWith("/") ? proxy : `${proxy}/`);
    return new URL(`${encodeURIComponent(sandboxId)}/${path.replace(/^\/+/, "")}`, root);
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
        if (providerApi) {
          headers.authorization = `Bearer ${Redacted.value(config.apiKey)}`;
          if (config.organizationId !== undefined) headers["X-Daytona-Organization-ID"] = config.organizationId;
        }
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

  const readJson = (operation: string, response: Response): Effect.Effect<unknown, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const text = await response.text();
        if (text.length > MAX_RESPONSE_BYTES) throw new Error("response too large");
        return JSON.parse(text);
      },
      catch: () => new UpstreamError({ operation, status: response.status }),
    });

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
    return send("resizeVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/resize`), { method: "POST", json: body }, true).pipe(
      Effect.flatMap((response) => decodeSandboxResponse("resizeVm", response)),
      Effect.map(({ vm }) => vm),
    );
  };

  const sandboxSnapshotName = (tenantId: string, cmuxId: string): string => `cmux-vm-${config.environment}-${tenantId}-${cmuxId}`.slice(0, 128);

  const idOf = <C, R>(owns: TenantOwnsResource<C, R>): Effect.Effect<UpstreamId> => Effect.sync(() => upstreamIdOf(owns));

  const execStream = (result: unknown): ReadableStream<Uint8Array> => {
    const record = isRecord(result) ? result : {};
    const exitCode = typeof record.exitCode === "number" && Number.isInteger(record.exitCode) ? record.exitCode : null;
    const stdout = typeof record.result === "string" ? record.result : "";
    const body = encoder.encode(JSON.stringify({ exitCode, stdout, stderr: "" }));
    return new ReadableStream({
      start(controller) {
        controller.enqueue(body);
        controller.close();
      },
    });
  };

  const toolboxRequest = (operation: string, sandbox: DaytonaSandbox, path: string, init: Parameters<typeof send>[2]) => {
    if (sandbox.toolboxProxyUrl === undefined) return Effect.fail(new UpstreamError({ operation, status: null }));
    return send(operation, toolboxUrl(sandbox.toolboxProxyUrl, sandbox.id, path), init, false).pipe(Effect.flatMap((response) => readJson(operation, response)));
  };

  return {
    getVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => getSandbox("getVm", id)), Effect.map(({ vm }) => vm)),

    getVmForWrite: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => getSandbox("getVmForWrite", id)), Effect.map(({ vm }) => vm)),

    createVm: (caller, spec, { source }) => {
      if (!sizeIsValid(spec.size)) return Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
      const sourceId = source === undefined ? null : upstreamIdOf(source.owns);
      const requested = sizeBody(spec.size);
      const body: Record<string, unknown> = {
        name: `cmux-vm-${config.environment}-${caller.value.tenantId}-${spec.cmuxId}`.slice(0, 128),
        snapshot: sourceId ?? sourceSnapshot(spec.size),
        labels: { cmux_tenant: caller.value.tenantId, cmux_id: spec.cmuxId, cmux_env: spec.environment },
        autoStopInterval: spec.idleTimeoutSeconds < 0 ? 0 : Math.max(1, Math.ceil(spec.idleTimeoutSeconds / 60)),
        ...requested,
      };
      if (spec.maxRunSeconds !== undefined) body.ttlMinutes = spec.maxRunSeconds < 0 ? 0 : Math.max(1, Math.ceil(spec.maxRunSeconds / 60));
      if (spec.autoDeleteSeconds !== undefined) body.autoDeleteInterval = spec.autoDeleteSeconds < 0 ? -1 : Math.ceil(spec.autoDeleteSeconds / 60);
      return send("createVm", mainUrl("/sandbox"), { method: "POST", json: body }, true).pipe(
        Effect.flatMap((response) => decodeSandboxResponse("createVm", response)),
        Effect.map(({ sandbox, vm }) => {
          const createdId = upstreamId(sandbox.id);
          const discard = deleteById("discardVm", `/sandbox/${encodeURIComponent(createdId)}`).pipe(Effect.ignore);
          return { upstreamId: createdId, vm, discard, grow: (size: SizeRequest) => growVm(createdId, vm, size) };
        }),
      );
    },

    startVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => action("startVm", id, "start"))),

    /** Daytona's default container class has no memory-preserving pause; pause is a native stop. */
    pauseVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => action("pauseVm", id, "stop"))),

    shutdownVm: (_vm, { owns }) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => send("shutdownVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/stop`), { method: "POST" }, true)),
        Effect.flatMap(drain),
      ),

    deleteVm: (_vm, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => deleteById("deleteVm", `/sandbox/${encodeURIComponent(id)}`))),

    snapshotForFork: (caller, _vm, spec, { owns }) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => {
          const snapshotName = sandboxSnapshotName(caller.value.tenantId, spec.cmuxId);
          return send("snapshotVm", mainUrl(`/sandbox/${encodeURIComponent(id)}/snapshot`), { method: "POST", json: { name: snapshotName, includeMemory: false } }, true).pipe(
            Effect.flatMap((response) => drain(response).pipe(Effect.as({ upstreamId: upstreamId(snapshotName), discard: deleteById("discardSnapshot", `/snapshots/${encodeURIComponent(snapshotName)}`).pipe(Effect.ignore) }))),
          );
        }),
      ),

    deleteSnapshot: (_snapshot, { owns }) => idOf(owns).pipe(Effect.flatMap((id) => deleteById("deleteSnapshot", `/snapshots/${encodeURIComponent(id)}`))),

    exec: (_vm, { owns }, spec) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("execVm", id)),
        Effect.flatMap(({ sandbox }) => {
          const envs: Record<string, string> = { ...spec.env };
          let command = spec.command;
          if (spec.stdinBase64 !== undefined) {
            envs.CMUX_DAYTONA_STDIN = spec.stdinBase64;
            envs.CMUX_DAYTONA_COMMAND = spec.command;
            command = `printf '%s' "$CMUX_DAYTONA_STDIN" | base64 -d | sh -c "$CMUX_DAYTONA_COMMAND"`;
          }
          const request: Record<string, unknown> = { command, ...(Object.keys(envs).length === 0 ? {} : { envs }) };
          if (spec.timeoutMs !== undefined) request.timeout = Math.max(1, Math.ceil(spec.timeoutMs / 1000));
          return toolboxRequest("execVm", sandbox, "/process/execute", { method: "POST", json: request });
        }),
        Effect.map(execStream),
      ),

    readFile: (_vm, { owns }, path, range) =>
      idOf(owns).pipe(
        Effect.flatMap((id) => getSandbox("readFile", id)),
        Effect.flatMap(({ sandbox }) => {
          if (sandbox.toolboxProxyUrl === undefined) return Effect.fail(new UpstreamError({ operation: "readFile", status: null }));
          const init = range === undefined ? { method: "GET" as const, timeoutMs: 900_000 } : { method: "GET" as const, headers: { range }, timeoutMs: 900_000 };
          return send("readFile", toolboxUrl(sandbox.toolboxProxyUrl, sandbox.id, `/files/download?path=${encodeURIComponent(path)}`), init, false).pipe(
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
          const proxy = sandbox.toolboxProxyUrl;
          if (proxy === undefined) return Effect.fail(new UpstreamError({ operation: "writeFile", status: null }));
          return send("writeFile", toolboxUrl(proxy, sandbox.id, `/files/upload-v2?path=${encodeURIComponent(file.path)}`), { method: "POST", body: file.body, length: file.length, timeoutMs: 900_000 }, false).pipe(
            Effect.flatMap(drain),
            Effect.flatMap(() =>
              file.mode === undefined
                ? Effect.void
                : send("writeFileMode", toolboxUrl(proxy, sandbox.id, `/files/permissions?path=${encodeURIComponent(file.path)}&mode=${file.mode.toString(8)}`), { method: "POST" }, false).pipe(Effect.flatMap(drain)),
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
