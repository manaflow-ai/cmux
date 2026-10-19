import { Effect, Redacted } from "effect";
import { UpstreamId, type UpstreamId as UpstreamIdType } from "../lib/ids.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import {
  UpstreamError,
  type CreatedResource,
  type CreateVmSpec,
  type ExecSpec,
  type FileRead,
  type SizeRequest,
  type UpstreamClientService,
  type UpstreamVm,
} from "./client.ts";
import { E2B_CAPABILITIES } from "../providers/e2b/capabilities.ts";
import { upstreamName } from "./naming.ts";
import type { Environment } from "../policy.ts";

const DEFAULT_API_URL = "https://api.e2b.app/";
const DEFAULT_SANDBOX_DOMAIN = "https://sandbox.e2b.app/";
const ENVD_PORT = "49983";
const DEFAULT_TIMEOUT_SECONDS = 86_400;
const MAX_EXEC_TIMEOUT_MS = 300_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const SLOW_REQUEST_TIMEOUT_MS = 120_000;
const TRANSFER_REQUEST_TIMEOUT_MS = 15 * 60_000;
const MIN_UPLOAD_ENVD_VERSION: readonly [number, number, number] = [0, 5, 7];
const MAX_BUFFERED_OUTPUT_BYTES = 8 * 1024 * 1024;

/** The optional template id is intentionally configuration, not tenant input. */
export interface E2bClientConfig {
  readonly apiKey: Redacted.Redacted<string>;
  readonly apiUrl?: string;
  readonly domain?: string;
  readonly fetch?: typeof globalThis.fetch;
  readonly environment: string;
  readonly templateId?: string;
}

interface E2bSandbox {
  readonly templateID?: unknown;
  readonly sandboxID?: unknown;
  readonly envdAccessToken?: unknown;
  readonly domain?: unknown;
  readonly startedAt?: unknown;
  readonly endAt?: unknown;
  readonly state?: unknown;
  readonly cpuCount?: unknown;
  readonly memoryMB?: unknown;
  readonly diskSizeMB?: unknown;
  readonly metadata?: unknown;
  readonly envdVersion?: unknown;
}

interface Connection {
  readonly id: string;
  readonly token: string;
  readonly domain: string;
  readonly envdVersion: string | null;
}

class HttpFailure extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`E2B HTTP ${status}`);
    this.status = status;
  }
}

class ConnectFailure extends Error {}

const idOf = <C, R>(proof: TenantOwnsResource<C, R>): Effect.Effect<UpstreamIdType> => Effect.sync(() => upstreamIdOf(proof));

const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {};

const stringValue = (value: unknown): string | null => (typeof value === "string" && value.length > 0 ? value : null);
const numberValue = (value: unknown): number | null => (typeof value === "number" && Number.isFinite(value) ? value : null);

const normalizeOrigin = (raw: string, message: string): URL => {
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") throw new Error(message);
  return url;
};

const domainUrl = (raw: string): URL => {
  const withScheme = raw.includes("://") ? raw : `https://${raw}`;
  const url = new URL(withScheme.endsWith("/") ? withScheme : `${withScheme}/`);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("E2B sandbox domain must be a bare HTTPS origin");
  }
  return url;
};

const envdDomain = (id: string, raw: string | null, configured: URL): URL => {
  if (raw === null || raw === "e2b.app" || raw === "sandbox.e2b.app") return configured;
  const parsed = domainUrl(raw);
  if (parsed.hostname === "e2b.app" || parsed.hostname === "sandbox.e2b.app") return configured;
  return new URL(`https://49983-${id}.${parsed.hostname}/`);
};

const asIso = (value: unknown): string => {
  const parsed = stringValue(value);
  return parsed ?? new Date(0).toISOString();
};

const stateOf = (value: unknown): string => {
  const state = stringValue(value);
  return state === "running" || state === "paused" ? state : state ?? "unknown";
};

const byteSize = (value: unknown): number => {
  const number = numberValue(value);
  if (number !== null) return number;
  if (typeof value === "string" && /^\d+$/u.test(value)) return Number(value);
  return 0;
};

const connectionFrom = (id: string, sandbox: E2bSandbox, configuredDomain: URL): Connection | null => {
  const token = stringValue(sandbox.envdAccessToken);
  if (token === null) return null;
  const rawDomain = stringValue(sandbox.domain);
  return { id, token, domain: envdDomain(id, rawDomain, configuredDomain).toString(), envdVersion: stringValue(sandbox.envdVersion) };
};

const encodeFrame = (message: unknown): Uint8Array => {
  const payload = new TextEncoder().encode(JSON.stringify(message));
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = 0;
  new DataView(frame.buffer).setUint32(1, payload.length);
  frame.set(payload, 5);
  return frame;
};

const concatBytes = (parts: ReadonlyArray<Uint8Array>): Uint8Array => {
  const size = parts.reduce((total, part) => total + part.byteLength, 0);
  const output = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.byteLength;
  }
  return output;
};

const decodeBase64 = (value: unknown): Uint8Array => {
  const encoded = stringValue(value);
  if (encoded === null) return new Uint8Array();
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
};

const pathId = (id: UpstreamIdType) => encodeURIComponent(id);

const sizeWithinLimits = (size: SizeRequest | undefined): boolean =>
  size === undefined ||
  ((size.vcpus === undefined || (size.vcpus > 0 && size.vcpus <= E2B_CAPABILITIES.maxVcpus)) &&
    (size.memoryMib === undefined || (size.memoryMib > 0 && size.memoryMib <= E2B_CAPABILITIES.maxMemoryMib)) &&
    (size.diskMib === undefined || (size.diskMib > 0 && size.diskMib <= E2B_CAPABILITIES.maxDiskMib)));

const timeoutSeconds = (seconds: number): number => (seconds < 0 ? DEFAULT_TIMEOUT_SECONDS : Math.ceil(seconds));

const versionAtLeast = (value: string | null, minimum: readonly [number, number, number]): boolean => {
  if (value === null) return false;
  const parts = value.split(".").map((part) => Number.parseInt(part, 10));
  return parts.length >= 3 && parts.every(Number.isFinite) && (parts[0] ?? 0) * 1_000_000 + (parts[1] ?? 0) * 1_000 + (parts[2] ?? 0) >= minimum[0] * 1_000_000 + minimum[1] * 1_000 + minimum[2];
};

const environmentOf = (value: string): Environment => value === "local" || value === "preview" || value === "staging" ? value : "production";

export function makeE2bUpstreamClient(config: E2bClientConfig): UpstreamClientService {
  const api = normalizeOrigin(config.apiUrl ?? DEFAULT_API_URL, "E2B API URL must be a bare HTTPS origin");
  const sandboxDomain = domainUrl(config.domain ?? DEFAULT_SANDBOX_DOMAIN);
  const send = config.fetch ?? globalThis.fetch.bind(globalThis);
  const connections = new Map<string, Connection>();
  const vmDetails = new Map<string, { readonly idleTimeoutSeconds: number; readonly updatedAt: string }>();

  const request = (operation: string, base: URL, path: string, init: RequestInit = {}, timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS): Effect.Effect<Response, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const url = new URL(path, base);
        const headers = new Headers(init.headers);
        headers.set("accept", "application/json");
        if (base.origin === api.origin) headers.set("X-API-Key", Redacted.value(config.apiKey));
        const response = await send(new Request(url, { ...init, headers, redirect: "manual", signal: init.signal ?? AbortSignal.timeout(timeoutMs) }));
        if (!response.ok) {
          await response.body?.cancel();
          throw new HttpFailure(response.status);
        }
        return response;
      },
      catch: (cause) => new UpstreamError({ operation, status: cause instanceof HttpFailure ? cause.status : null }),
    });

  const json = (operation: string, response: Response): Effect.Effect<Record<string, unknown>, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const value: unknown = await response.json();
        return asRecord(value);
      },
      catch: () => new UpstreamError({ operation, status: response.status }),
    });

  const rawSandbox = (operation: string, id: UpstreamIdType): Effect.Effect<E2bSandbox, UpstreamError> =>
    request(operation, api, `/sandboxes/${pathId(id)}`).pipe(Effect.flatMap((response) => json(operation, response)));

  const remember = (id: UpstreamIdType, sandbox: E2bSandbox, idleTimeoutSeconds?: number) => {
    const connection = connectionFrom(id, sandbox, sandboxDomain);
    if (connection !== null) connections.set(id, connection);
    const previous = vmDetails.get(id);
    vmDetails.set(id, {
      idleTimeoutSeconds: idleTimeoutSeconds ?? previous?.idleTimeoutSeconds ?? DEFAULT_TIMEOUT_SECONDS,
      updatedAt: new Date().toISOString(),
    });
  };

  const toVm = (id: UpstreamIdType, sandbox: E2bSandbox): UpstreamVm => {
    const details = vmDetails.get(id);
    const startedAt = asIso(sandbox.startedAt);
    return {
      state: stateOf(sandbox.state),
      resources: {
        cpu: numberValue(sandbox.cpuCount) ?? 0,
        memory: numberValue(sandbox.memoryMB) ?? 0,
        storage: byteSize(sandbox.diskSizeMB),
      },
      idleTimeoutSeconds: details?.idleTimeoutSeconds ?? null,
      maxRunSeconds: null,
      autoDeleteSeconds: null,
      createdAt: startedAt,
      updatedAt: details?.updatedAt ?? startedAt,
    };
  };

  const getRaw = (operation: string, id: UpstreamIdType): Effect.Effect<{ readonly sandbox: E2bSandbox; readonly vm: UpstreamVm }, UpstreamError> =>
    rawSandbox(operation, id).pipe(
      Effect.tap((sandbox) => Effect.sync(() => remember(id, sandbox))),
      Effect.map((sandbox) => ({ sandbox, vm: toVm(id, sandbox) })),
    );

  const timeoutFor = (id: UpstreamIdType): number => vmDetails.get(id)?.idleTimeoutSeconds ?? DEFAULT_TIMEOUT_SECONDS;

  const connectSandbox = (operation: string, id: UpstreamIdType, connection: Connection, timeout = timeoutFor(id)): Effect.Effect<Connection, UpstreamError> =>
    request(operation, api, `/v2/sandboxes/${pathId(id)}/connect`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ timeout }),
    }, SLOW_REQUEST_TIMEOUT_MS).pipe(
      Effect.flatMap((response) => json(operation, response)),
      Effect.map((sandbox) => connectionFrom(id, sandbox, sandboxDomain) ?? connection),
      Effect.tap((next) => Effect.sync(() => { connections.set(id, next); })),
    );

  const brokerConnection = (operation: string, id: UpstreamIdType): Effect.Effect<Connection, UpstreamError> =>
    getRaw(operation, id).pipe(
      Effect.flatMap(({ sandbox }) => {
        const connection = connectionFrom(id, sandbox, sandboxDomain) ?? connections.get(id);
        return connection === undefined ? Effect.fail(new UpstreamError({ operation, status: 502 })) : connectSandbox(operation, id, connection, timeoutFor(id));
      }),
    );

  const deleteResource = (operation: string, base: URL, path: string): Effect.Effect<"deleted" | "gone", UpstreamError> =>
    request(operation, base, path, { method: "DELETE" }, SLOW_REQUEST_TIMEOUT_MS).pipe(
      Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel())).pipe(Effect.as("deleted" as const))),
      Effect.catchIf((error) => error.status === 404, () => Effect.succeed("gone" as const)),
    );

  const discardVm = (id: UpstreamIdType): Effect.Effect<void, never> => deleteResource("discardVm", api, `/sandboxes/${pathId(id)}`).pipe(Effect.ignore);
  const discardSnapshot = (id: UpstreamIdType): Effect.Effect<void, never> => deleteResource("discardSnapshot", api, `/templates/${pathId(id)}`).pipe(Effect.ignore);

  const connectHeaders = (connection: Connection): Headers => {
    const headers = new Headers({
      "content-type": "application/connect+json",
      "connect-protocol-version": "1",
      "e2b-sandbox-id": connection.id,
      "e2b-sandbox-port": ENVD_PORT,
      "x-access-token": connection.token,
    });
    return headers;
  };

  const envdRequest = (operation: string, connection: Connection, path: string, init: RequestInit = {}, timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS): Effect.Effect<Response, UpstreamError> => {
    const base = domainUrl(connection.domain);
    const headers = new Headers(init.headers);
    headers.set("e2b-sandbox-id", connection.id);
    headers.set("e2b-sandbox-port", ENVD_PORT);
    headers.set("x-access-token", connection.token);
    return request(operation, base, path, { ...init, headers }, timeoutMs);
  };

  const connectRequest = (operation: string, connection: Connection, path: string, message: unknown, timeoutMs?: number, requestTimeoutMs?: number): Effect.Effect<Response, UpstreamError> => {
    const headers = connectHeaders(connection);
    if (timeoutMs !== undefined) headers.set("connect-timeout-ms", String(timeoutMs));
    const bytes = encodeFrame(message);
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(bytes); controller.close(); } });
    return envdRequest(operation, connection, path, { method: "POST", headers, body }, requestTimeoutMs ?? timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS);
  };

  const connectUnaryRequest = (operation: string, connection: Connection, path: string, message: unknown): Effect.Effect<Response, UpstreamError> => {
    const headers = new Headers({ "content-type": "application/json", "connect-protocol-version": "1" });
    return envdRequest(operation, connection, path, { method: "POST", headers, body: JSON.stringify(message) });
  };

  const sendStdin = (connection: Connection, pid: number, stdinBase64: string): Promise<void> =>
    Effect.runPromise(
      connectUnaryRequest("execVm.sendInput", connection, "/process.Process/SendInput", {
        process: { pid },
        input: { stdin: stdinBase64 },
      }).pipe(
        Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))),
        Effect.zipRight(
          connectUnaryRequest("execVm.closeStdin", connection, "/process.Process/CloseStdin", { process: { pid } }).pipe(
            Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))),
          ),
        ),
      ),
    );

  const chmodFile = (connection: Connection, path: string, mode: number): Effect.Effect<void, UpstreamError> =>
    connectRequest("writeFile.mode", connection, "/process.Process/Start", {
      process: { cmd: "/bin/chmod", args: [mode.toString(8), path] },
      stdin: false,
    }).pipe(
      Effect.flatMap((response) => Effect.promise(async () => void (await new Response(execStream(response, () => Promise.resolve())).text()))),
    );

  const pauseById = (id: UpstreamIdType, operation: string): Effect.Effect<UpstreamVm, UpstreamError> =>
    request(operation, api, `/sandboxes/${pathId(id)}/pause`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ memory: true }) }, SLOW_REQUEST_TIMEOUT_MS).pipe(
      Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))),
      Effect.zipRight(getRaw(operation, id)),
      Effect.map(({ vm }) => vm),
    );

  const execStream = (response: Response, onStart: (pid: number) => Promise<void>): ReadableStream<Uint8Array> => {
    if (response.body === null) throw new ConnectFailure("E2B exec response had no body");
    const reader = response.body.getReader();
    const encoder = new TextEncoder();
    const decoders = { stdout: new TextDecoder(), stderr: new TextDecoder() };
    let pending = new Uint8Array();
    let exitCode: number | null = null;
    let streamField: "stdout" | "stderr" | null = null;
    let bufferedField: "stdout" | "stderr" = "stdout";
    let buffered = "";
    let startPromise: Promise<void> | null = null;
    const escaped = (value: string) => JSON.stringify(value).slice(1, -1);
    const appendBuffered = (value: string) => {
      const room = MAX_BUFFERED_OUTPUT_BYTES - buffered.length;
      if (room > 0) buffered += value.slice(0, room);
    };
    const emitMessage = (message: Record<string, unknown>, controller: ReadableStreamDefaultController<Uint8Array>) => {
      const event = asRecord(asRecord(message.event).event ?? message.event);
      const data = asRecord(event.data);
      for (const field of ["stdout", "stderr"] as const) {
        const bytes = decodeBase64(data[field]);
        if (bytes.byteLength === 0) continue;
        const text = decoders[field].decode(bytes, { stream: true });
        if (streamField === null) {
          streamField = field;
          bufferedField = field === "stdout" ? "stderr" : "stdout";
          controller.enqueue(encoder.encode(`{"${field}":"`));
        }
        if (field === streamField) controller.enqueue(encoder.encode(escaped(text)));
        else appendBuffered(text);
      }
      const start = asRecord(event.start);
      const pid = numberValue(start.pid);
      if (pid !== null && startPromise === null) startPromise = onStart(pid);
      const end = asRecord(event.end);
      const code = numberValue(end.exitCode);
      if (code !== null) exitCode = code;
      else if (end.exited === true) exitCode = 0;
    };
    return new ReadableStream<Uint8Array>({
      async start(controller) {
        try {
          while (true) {
            const next = await reader.read();
            if (next.done) break;
            pending = new Uint8Array(concatBytes([pending, next.value]));
            while (pending.byteLength >= 5) {
              const length = new DataView(pending.buffer, pending.byteOffset, pending.byteLength).getUint32(1);
              if (pending.byteLength < length + 5) break;
              const flags = pending[0] ?? 0;
              const payload = pending.slice(5, length + 5);
              pending = pending.slice(length + 5);
              const message = asRecord(JSON.parse(new TextDecoder().decode(payload)));
              if ((flags & 2) !== 0) {
                const error = asRecord(message.error);
                if (Object.keys(error).length > 0) exitCode = null;
              } else {
                emitMessage(message, controller);
                if (startPromise !== null) {
                  await startPromise;
                  startPromise = null;
                }
              }
            }
          }
          if (pending.byteLength !== 0) throw new ConnectFailure("truncated E2B Connect frame");
          for (const field of ["stdout", "stderr"] as const) {
            const tail = decoders[field].decode();
            if (tail.length === 0) continue;
            if (streamField === field) controller.enqueue(encoder.encode(escaped(tail)));
            else appendBuffered(tail);
          }
          if (streamField === null) {
            streamField = "stdout";
            bufferedField = "stderr";
            controller.enqueue(encoder.encode('{"stdout":""'));
          }
          controller.enqueue(encoder.encode(`","${bufferedField}":${JSON.stringify(buffered)},"exitCode":${exitCode === null ? "null" : String(exitCode)}}`));
          controller.close();
        } catch (error) {
          controller.error(error);
        } finally {
          reader.releaseLock();
        }
      },
    });
  };

  const listEntries = (response: Record<string, unknown>): ReadonlyArray<{ readonly name: string; readonly kind: string }> => {
    const entries = Array.isArray(response.entries) ? response.entries : [];
    return entries.map((entry) => {
      const item = asRecord(entry);
      const type = stringValue(item.type) ?? "FILE_TYPE_UNSPECIFIED";
      return { name: stringValue(item.name) ?? stringValue(item.path) ?? "", kind: type.toLowerCase().includes("directory") ? "directory" : type.toLowerCase().includes("symlink") ? "symlink" : "file" };
    });
  };

  return {
    getVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => getRaw("getVm", id).pipe(Effect.map(({ vm }) => vm))),

    getVmForWrite: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => getRaw("getVmForWrite", id).pipe(Effect.map(({ vm }) => vm))),

    createVm: (caller, spec: CreateVmSpec, { source }) => {
      if (spec.idleTimeoutSeconds === 0) return Effect.fail(new UpstreamError({ operation: "createVm", status: 422 }));
      if (spec.maxRunSeconds !== undefined || spec.autoDeleteSeconds !== undefined) return Effect.fail(new UpstreamError({ operation: "createVm", status: 409 }));
      if (!sizeWithinLimits(spec.size)) return Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
      const body = {
        templateID: config.templateId ?? "base",
        timeout: timeoutSeconds(spec.idleTimeoutSeconds),
        autoPause: true,
        autoPauseMemory: true,
        secure: true,
        metadata: {
          cmux_tenant: caller.value.tenantId,
          cmux_id: spec.cmuxId,
          cmux_env: spec.environment,
        },
      };
      const create = source === undefined
        ? request("createVm", api, "/v2/sandboxes", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }, SLOW_REQUEST_TIMEOUT_MS)
        : Effect.flatMap(idOf(source.owns), (sourceId) => request("createVm", api, "/v2/sandboxes", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ...body, templateID: sourceId }) }, SLOW_REQUEST_TIMEOUT_MS));
      return create.pipe(
        Effect.flatMap((response) => json("createVm", response)),
        Effect.flatMap((sandbox) => {
          const id = stringValue(sandbox.sandboxID);
          if (id === null) return Effect.fail(new UpstreamError({ operation: "createVm", status: 502 }));
          const upstreamId = UpstreamId.make(id);
          remember(upstreamId, sandbox, spec.idleTimeoutSeconds);
          return getRaw("createVm", upstreamId).pipe(
            Effect.map(({ vm }) => {
              const grow = (size: SizeRequest): Effect.Effect<UpstreamVm, UpstreamError> => {
                if (!sizeWithinLimits(size)) return Effect.fail(new UpstreamError({ operation: "resizeVm", status: 400 }));
                const needsResize =
                  (size.vcpus !== undefined && size.vcpus > vm.resources.cpu) ||
                  (size.memoryMib !== undefined && size.memoryMib > vm.resources.memory) ||
                  (size.diskMib !== undefined && size.diskMib > vm.resources.storage);
                return needsResize ? Effect.fail(new UpstreamError({ operation: "resizeVm", status: 409 })) : Effect.succeed(vm);
              };
              return { upstreamId, vm, discard: discardVm(upstreamId), grow } satisfies CreatedResource & { readonly vm: UpstreamVm; readonly grow: (size: SizeRequest) => Effect.Effect<UpstreamVm, UpstreamError> };
            }),
          );
        }),
      );
    },

    startVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => getRaw("startVm", id).pipe(
      Effect.flatMap(({ sandbox }) => {
        const connection = connectionFrom(id, sandbox, sandboxDomain) ?? connections.get(id);
        return connection === undefined ? Effect.fail(new UpstreamError({ operation: "startVm", status: 502 })) : connectSandbox("startVm", id, connection);
      }),
      Effect.zipRight(getRaw("startVm", id)),
      Effect.map(({ vm }) => vm),
    )),

    pauseVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => pauseById(id, "pauseVm")),

    shutdownVm: () => Effect.fail(new UpstreamError({ operation: "shutdownVm", status: 409 })),

    deleteVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => deleteResource("deleteVm", api, `/sandboxes/${pathId(id)}`).pipe(Effect.tap(() => Effect.sync(() => { connections.delete(id); vmDetails.delete(id); })))),

    snapshotForFork: (caller, _vm, spec, { owns }) => Effect.flatMap(idOf(owns), (id) => request("snapshotVm", api, `/sandboxes/${pathId(id)}/snapshots`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: upstreamName(environmentOf(config.environment), caller.value.tenantId, spec.cmuxId), memory: true }),
      }, SLOW_REQUEST_TIMEOUT_MS).pipe(
        Effect.flatMap((response) => json("snapshotVm", response)),
        Effect.flatMap((snapshot) => {
          const snapshotId = stringValue(snapshot.snapshotID);
          return snapshotId === null
            ? Effect.fail(new UpstreamError({ operation: "snapshotVm", status: 502 }))
            : Effect.succeed({ upstreamId: UpstreamId.make(snapshotId), discard: discardSnapshot(UpstreamId.make(snapshotId)) });
        }),
      )),

    deleteSnapshot: (_snapshot, { owns }) => Effect.flatMap(idOf(owns), (id) => deleteResource("deleteSnapshot", api, `/templates/${pathId(id)}`)),

    exec: (_vm, { owns }, spec: ExecSpec) => {
      return Effect.flatMap(idOf(owns), (id) => brokerConnection("execVm", id).pipe(
        Effect.flatMap((connection) => {
          const process = spec.linuxUser === undefined
            ? { cmd: "/bin/sh", args: ["-lc", spec.command] }
            : { cmd: "/usr/sbin/runuser", args: ["-u", spec.linuxUser, "--", "/bin/sh", "-lc", spec.command] };
          const message = { process: { ...process, ...(spec.env === undefined ? {} : { envs: spec.env }) }, stdin: spec.stdinBase64 !== undefined };
          const timeout = Math.min(MAX_EXEC_TIMEOUT_MS, Math.max(1, spec.timeoutMs ?? 30_000));
          return connectRequest("execVm", connection, "/process.Process/Start", message, timeout, timeout + 30_000).pipe(
            Effect.flatMap((response) => response.body === null
              ? Effect.fail(new UpstreamError({ operation: "execVm", status: response.status }))
              : Effect.succeed(execStream(response, (pid) => spec.stdinBase64 === undefined ? Promise.resolve() : sendStdin(connection, pid, spec.stdinBase64)))),
          );
        }),
      ));
    },

    readFile: (_vm, { owns }, path, range) => {
      return Effect.flatMap(idOf(owns), (id) => brokerConnection("readFile", id).pipe(
        Effect.flatMap((connection) => {
          const query = new URLSearchParams({ path });
          const headers = new Headers();
          if (range !== undefined) headers.set("range", range);
          return envdRequest("readFile", connection, `/files?${query.toString()}`, { method: "GET", headers }, TRANSFER_REQUEST_TIMEOUT_MS).pipe(
            Effect.flatMap((response) => {
              if (response.body === null) return Effect.fail(new UpstreamError({ operation: "readFile", status: response.status }));
              return Effect.succeed<FileRead>({
                status: response.status === 206 ? 206 : 200,
                contentRange: response.headers.get("content-range"),
                contentLength: response.headers.get("content-length"),
                body: response.body,
              });
            }),
          );
        }),
      ));
    },

    writeFile: (_vm, { owns }, file) => {
      return Effect.flatMap(idOf(owns), (id) => brokerConnection("writeFile", id).pipe(
        Effect.flatMap((connection) => {
          if (!versionAtLeast(connection.envdVersion, MIN_UPLOAD_ENVD_VERSION)) return Effect.fail(new UpstreamError({ operation: "writeFile", status: 409 }));
          const query = new URLSearchParams({ path: file.path });
          const sized = new FixedLengthStream(file.length);
          void file.body.pipeTo(sized.writable).catch(() => undefined);
          return envdRequest("writeFile", connection, `/files?${query.toString()}`, {
            method: "POST",
            headers: { "content-type": "application/octet-stream", "content-length": String(file.length) },
            body: sized.readable,
          }, TRANSFER_REQUEST_TIMEOUT_MS).pipe(
            Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))),
            Effect.zipRight(file.mode === undefined ? Effect.void : chmodFile(connection, file.path, file.mode)),
          );
        }),
      ));
    },

    listFiles: (_vm, { owns }, path) => {
      return Effect.flatMap(idOf(owns), (id) => brokerConnection("listFiles", id).pipe(
        Effect.flatMap((connection) => connectUnaryRequest("listFiles", connection, "/filesystem.Filesystem/ListDir", { path }).pipe(Effect.flatMap((response) => json("listFiles", response)))),
        Effect.map(listEntries),
      ));
    },
  };
}
