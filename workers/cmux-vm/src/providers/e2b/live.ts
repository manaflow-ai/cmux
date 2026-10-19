import { Effect, Redacted } from "effect";
import { UpstreamId, type UpstreamId as UpstreamIdType } from "../../lib/ids.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../../proofs/tenant-owns-resource.ts";
import {
  UpstreamError,
  type CreatedResource,
  type CreateVmSpec,
  type ExecSpec,
  type FileRead,
  type SizeRequest,
  type UpstreamClientService,
  type UpstreamVm,
} from "../../upstream/client.ts";
import { E2B_CAPABILITIES } from "./capabilities.ts";

const DEFAULT_API_URL = "https://api.e2b.app/";
const DEFAULT_SANDBOX_DOMAIN = "https://sandbox.e2b.app/";
const ENVD_PORT = "49983";
const DEFAULT_TIMEOUT_SECONDS = 86_400;
const MAX_EXEC_TIMEOUT_MS = 300_000;

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
}

interface Connection {
  readonly id: string;
  readonly token: string;
  readonly domain: string;
}

class HttpFailure extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`E2B HTTP ${status}`);
    this.status = status;
  }
}

class ConnectFailure extends Error {}

const idOf = <C, R>(proof: TenantOwnsResource<C, R>): UpstreamIdType => upstreamIdOf(proof);

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
  return { id, token, domain: rawDomain === null ? configuredDomain.toString() : domainUrl(rawDomain).toString() };
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

const timeoutSeconds = (seconds: number): number => {
  // E2B requires a positive TTL. A cmux "no idle timeout" VM gets E2B's documented 24-hour maximum.
  return seconds < 0 ? DEFAULT_TIMEOUT_SECONDS : Math.max(1, Math.ceil(seconds));
};

export function makeE2bUpstreamClient(config: E2bClientConfig): UpstreamClientService {
  const api = normalizeOrigin(config.apiUrl ?? DEFAULT_API_URL, "E2B API URL must be a bare HTTPS origin");
  const sandboxDomain = domainUrl(config.domain ?? DEFAULT_SANDBOX_DOMAIN);
  const send = config.fetch ?? globalThis.fetch.bind(globalThis);
  const connections = new Map<string, Connection>();
  const vmDetails = new Map<string, { readonly idleTimeoutSeconds: number | null; readonly maxRunSeconds: number | null; readonly autoDeleteSeconds: number | null; readonly updatedAt: string }>();

  const request = (operation: string, base: URL, path: string, init: RequestInit = {}): Effect.Effect<Response, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const url = new URL(path, base);
        const headers = new Headers(init.headers);
        headers.set("accept", "application/json");
        if (base.origin === api.origin) headers.set("X-API-Key", Redacted.value(config.apiKey));
        const response = await send(new Request(url, { ...init, headers, redirect: "manual" }));
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

  const remember = (id: UpstreamIdType, sandbox: E2bSandbox, details?: { readonly idleTimeoutSeconds: number | null; readonly maxRunSeconds: number | null; readonly autoDeleteSeconds: number | null }) => {
    const connection = connectionFrom(id, sandbox, sandboxDomain);
    if (connection !== null) connections.set(id, connection);
    const previous = vmDetails.get(id);
    vmDetails.set(id, {
      idleTimeoutSeconds: details?.idleTimeoutSeconds ?? previous?.idleTimeoutSeconds ?? null,
      maxRunSeconds: details?.maxRunSeconds ?? previous?.maxRunSeconds ?? null,
      autoDeleteSeconds: details?.autoDeleteSeconds ?? previous?.autoDeleteSeconds ?? null,
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
      maxRunSeconds: details?.maxRunSeconds ?? null,
      autoDeleteSeconds: details?.autoDeleteSeconds ?? null,
      createdAt: startedAt,
      updatedAt: details?.updatedAt ?? startedAt,
    };
  };

  const getRaw = (operation: string, id: UpstreamIdType): Effect.Effect<{ readonly sandbox: E2bSandbox; readonly vm: UpstreamVm }, UpstreamError> =>
    rawSandbox(operation, id).pipe(
      Effect.tap((sandbox) => Effect.sync(() => remember(id, sandbox))),
      Effect.map((sandbox) => ({ sandbox, vm: toVm(id, sandbox) })),
    );

  const connectionFor = (operation: string, id: UpstreamIdType): Effect.Effect<Connection, UpstreamError> =>
    getRaw(operation, id).pipe(
      Effect.flatMap(({ sandbox }) => {
        const connection = connectionFrom(id, sandbox, sandboxDomain) ?? connections.get(id);
        return connection === undefined ? Effect.fail(new UpstreamError({ operation, status: 502 })) : Effect.succeed(connection);
      }),
    );

  const deleteResource = (operation: string, base: URL, path: string): Effect.Effect<"deleted" | "gone", UpstreamError> =>
    request(operation, base, path, { method: "DELETE" }).pipe(
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

  const envdRequest = (operation: string, connection: Connection, path: string, init: RequestInit = {}): Effect.Effect<Response, UpstreamError> => {
    const base = domainUrl(connection.domain);
    const headers = new Headers(init.headers);
    headers.set("e2b-sandbox-id", connection.id);
    headers.set("e2b-sandbox-port", ENVD_PORT);
    headers.set("x-access-token", connection.token);
    return request(operation, base, path, { ...init, headers });
  };

  const connectRequest = (operation: string, connection: Connection, path: string, message: unknown, timeoutMs?: number): Effect.Effect<Response, UpstreamError> => {
    const headers = connectHeaders(connection);
    if (timeoutMs !== undefined) headers.set("connect-timeout-ms", String(timeoutMs));
    const bytes = encodeFrame(message);
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(bytes); controller.close(); } });
    return envdRequest(operation, connection, path, { method: "POST", headers, body });
  };

  const connectUnaryRequest = (operation: string, connection: Connection, path: string, message: unknown): Effect.Effect<Response, UpstreamError> => {
    const headers = new Headers({ "content-type": "application/json", "connect-protocol-version": "1" });
    return envdRequest(operation, connection, path, { method: "POST", headers, body: JSON.stringify(message) });
  };

  const pauseById = (id: UpstreamIdType, operation: string): Effect.Effect<UpstreamVm, UpstreamError> =>
    request(operation, api, `/sandboxes/${pathId(id)}/pause`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ memory: true }) }).pipe(
      Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))),
      Effect.zipRight(getRaw(operation, id)),
      Effect.map(({ vm }) => vm),
    );

  const execStream = (response: Response): ReadableStream<Uint8Array> => {
    if (response.body === null) throw new ConnectFailure("E2B exec response had no body");
    const reader = response.body.getReader();
    const encoder = new TextEncoder();
    const stdoutDecoder = new TextDecoder();
    const stderrDecoder = new TextDecoder();
    let pending = new Uint8Array();
    let exitCode: number | null = null;
    let stderr = "";
    const escaped = (value: string) => JSON.stringify(value).slice(1, -1);
    const emitMessage = (message: Record<string, unknown>, controller: ReadableStreamDefaultController<Uint8Array>) => {
      const event = asRecord(asRecord(message.event).event ?? message.event);
      const data = asRecord(event.data);
      const stdout = decodeBase64(data.stdout);
      if (stdout.byteLength > 0) controller.enqueue(encoder.encode(escaped(stdoutDecoder.decode(stdout, { stream: true }))));
      const stderrBytes = decodeBase64(data.stderr);
      if (stderrBytes.byteLength > 0) stderr += stderrDecoder.decode(stderrBytes, { stream: true });
      const end = asRecord(event.end);
      const code = numberValue(end.exitCode);
      if (code !== null) exitCode = code;
    };
    return new ReadableStream<Uint8Array>({
      async start(controller) {
        controller.enqueue(encoder.encode('{"stdout":"'));
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
                if (Object.keys(error).length > 0) throw new ConnectFailure(stringValue(error.message) ?? "E2B Connect request failed");
              } else {
                emitMessage(message, controller);
              }
            }
          }
          if (pending.byteLength !== 0) throw new ConnectFailure("truncated E2B Connect frame");
          const stdoutTail = stdoutDecoder.decode();
          if (stdoutTail.length > 0) controller.enqueue(encoder.encode(escaped(stdoutTail)));
          stderr += stderrDecoder.decode();
          controller.enqueue(encoder.encode(`","stderr":${JSON.stringify(stderr)},"exitCode":${exitCode === null ? "null" : String(exitCode)}}`));
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
    getVm: (_vm, { owns }) => getRaw("getVm", idOf(owns)).pipe(Effect.map(({ vm }) => vm)),

    getVmForWrite: (_vm, { owns }) => getRaw("getVmForWrite", idOf(owns)).pipe(Effect.map(({ vm }) => vm)),

    createVm: (caller, spec: CreateVmSpec, { source }) => {
      if (!sizeWithinLimits(spec.size)) return Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
      const sourceId = source === undefined ? null : idOf(source.owns);
      const body = {
        templateID: sourceId ?? config.templateId ?? "base",
        timeout: timeoutSeconds(spec.idleTimeoutSeconds),
        autoPause: true,
        autoPauseMemory: true,
        secure: true,
        metadata: {
          cmux_tenant: caller.value.tenantId,
          cmux_id: spec.cmuxId,
          cmux_environment: config.environment,
        },
      };
      return request("createVm", api, "/v2/sandboxes", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).pipe(
        Effect.flatMap((response) => json("createVm", response)),
        Effect.flatMap((sandbox) => {
          const id = stringValue(sandbox.sandboxID);
          if (id === null) return Effect.fail(new UpstreamError({ operation: "createVm", status: 502 }));
          const upstreamId = UpstreamId.make(id);
          remember(upstreamId, sandbox, {
            idleTimeoutSeconds: spec.idleTimeoutSeconds,
            maxRunSeconds: spec.maxRunSeconds ?? null,
            autoDeleteSeconds: spec.autoDeleteSeconds ?? null,
          });
          const vm = toVm(upstreamId, sandbox);
          const grow = (size: SizeRequest): Effect.Effect<UpstreamVm, UpstreamError> => {
            if (!sizeWithinLimits(size)) return Effect.fail(new UpstreamError({ operation: "resizeVm", status: 400 }));
            const needsResize =
              (size.vcpus !== undefined && size.vcpus > vm.resources.cpu) ||
              (size.memoryMib !== undefined && size.memoryMib > vm.resources.memory) ||
              (size.diskMib !== undefined && size.diskMib > vm.resources.storage);
            return needsResize ? Effect.fail(new UpstreamError({ operation: "resizeVm", status: 409 })) : Effect.succeed(vm);
          };
          return Effect.succeed<CreatedResource & { readonly vm: UpstreamVm; readonly grow: (size: SizeRequest) => Effect.Effect<UpstreamVm, UpstreamError> }>({
            upstreamId,
            vm,
            discard: discardVm(upstreamId),
            grow,
          });
        }),
      );
    },

    startVm: (_vm, { owns }) => {
      const id = idOf(owns);
      return request("startVm", api, `/sandboxes/${pathId(id)}/resume`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({}) }).pipe(
        Effect.flatMap((response) => json("startVm", response)),
        Effect.zipRight(getRaw("startVm", id)),
        Effect.map(({ vm }) => vm),
      );
    },

    pauseVm: (_vm, { owns }) => {
      return pauseById(idOf(owns), "pauseVm");
    },

    shutdownVm: (_vm, { owns }) =>
      // E2B has no stopped state. The control-plane stop operation is intentionally the documented pause compatibility path.
      pauseById(idOf(owns), "shutdownVm").pipe(Effect.asVoid),

    deleteVm: (_vm, { owns }) => {
      const id = idOf(owns);
      return deleteResource("deleteVm", api, `/sandboxes/${pathId(id)}`).pipe(Effect.tap(() => Effect.sync(() => { connections.delete(id); vmDetails.delete(id); })));
    },

    snapshotForFork: (caller, _vm, spec, { owns }) => {
      const id = idOf(owns);
      return request("snapshotVm", api, `/sandboxes/${pathId(id)}/snapshots`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: `${config.environment}-${caller.value.tenantId}-${spec.cmuxId}`, memory: true }),
      }).pipe(
        Effect.flatMap((response) => json("snapshotVm", response)),
        Effect.flatMap((snapshot) => {
          const snapshotId = stringValue(snapshot.snapshotID);
          return snapshotId === null
            ? Effect.fail(new UpstreamError({ operation: "snapshotVm", status: 502 }))
            : Effect.succeed({ upstreamId: UpstreamId.make(snapshotId), discard: discardSnapshot(UpstreamId.make(snapshotId)) });
        }),
      );
    },

    deleteSnapshot: (_snapshot, { owns }) => deleteResource("deleteSnapshot", api, `/templates/${pathId(idOf(owns))}`),

    exec: (_vm, { owns }, spec: ExecSpec) => {
      const id = idOf(owns);
      return connectionFor("execVm", id).pipe(
        Effect.flatMap((connection) => {
          const message = { process: { cmd: "/bin/sh", args: ["-lc", spec.command], ...(spec.env === undefined ? {} : { envs: spec.env }) }, stdin: spec.stdinBase64 !== undefined };
          const timeout = Math.min(MAX_EXEC_TIMEOUT_MS, Math.max(1, spec.timeoutMs ?? 30_000));
          return connectRequest("execVm", connection, "/process.Process/Start", message, timeout).pipe(
            Effect.map((response) => execStream(response)),
          );
        }),
      );
    },

    readFile: (_vm, { owns }, path, range) => {
      const id = idOf(owns);
      return connectionFor("readFile", id).pipe(
        Effect.flatMap((connection) => {
          const query = new URLSearchParams({ path });
          const headers = new Headers();
          if (range !== undefined) headers.set("range", range);
          return envdRequest("readFile", connection, `/files?${query.toString()}`, { method: "GET", headers }).pipe(
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
      );
    },

    writeFile: (_vm, { owns }, file) => {
      const id = idOf(owns);
      return connectionFor("writeFile", id).pipe(
        Effect.flatMap((connection) => {
          const query = new URLSearchParams({ path: file.path });
          const sized = new FixedLengthStream(file.length);
          void file.body.pipeTo(sized.writable).catch(() => undefined);
          return envdRequest("writeFile", connection, `/files?${query.toString()}`, {
            method: "POST",
            headers: { "content-type": "application/octet-stream", "content-length": String(file.length) },
            body: sized.readable,
          }).pipe(Effect.flatMap((response) => Effect.promise(async () => void (await response.body?.cancel()))));
        }),
      );
    },

    listFiles: (_vm, { owns }, path) => {
      const id = idOf(owns);
      return connectionFor("listFiles", id).pipe(
        Effect.flatMap((connection) => connectUnaryRequest("listFiles", connection, "/filesystem.Filesystem/ListDir", { path }).pipe(Effect.flatMap((response) => json("listFiles", response)))),
        Effect.map(listEntries),
      );
    },
  };
}
