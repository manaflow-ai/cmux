/**
 * The upstream VM provider, as this service sees it.
 *
 * Every method demands gdp-ts proofs about its exact named arguments, and the
 * upstream id of an existing resource comes only from a TenantOwnsResource
 * proof. A create returns the new upstream id once, for the ownership table,
 * with a `discard` effect that deletes exactly that resource if recording it
 * fails. The raw HTTP request function and the provider key are private to
 * `makeUpstreamClient`; nothing else in the Worker can reach the provider.
 * See upstream/PINNED.json for the pinned provider API surface.
 */
import type { Named } from "@gdp-ts/core";
import { Context, Data, Effect, Redacted, Schema } from "effect";
import type { Principal } from "../domain/principal.ts";
import { UpstreamId, type SnapshotId, type VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { execResultStream } from "./exec-stream.ts";

export class UpstreamError extends Data.TaggedError("UpstreamError")<{
  readonly operation: string;
  /** HTTP status from the provider, or null when no response arrived. */
  readonly status: number | null;
}> {}

/** The fields of the provider's VM record this service reads. Everything else is ignored. */
export const UpstreamVm = Schema.Struct({
  state: Schema.String,
  resources: Schema.Struct({ cpu: Schema.Number, memory: Schema.Number, storage: Schema.Number }),
  idleTimeoutSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  maxRunSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  autoDeleteSeconds: Schema.optional(Schema.NullOr(Schema.Number)),
  createdAt: Schema.String,
  updatedAt: Schema.String,
});
export type UpstreamVm = typeof UpstreamVm.Type;

const CreatedVm = Schema.Struct({ id: UpstreamId, ...UpstreamVm.fields });
const CreatedSnapshot = Schema.Struct({ snapshotId: UpstreamId });
const DirListing = Schema.Struct({
  entries: Schema.Array(Schema.Struct({ name: Schema.String, kind: Schema.String })),
});

export interface CreatedResource {
  /** The provider id of the new resource, to record in the ownership table and nowhere else. */
  readonly upstreamId: UpstreamId;
  /** Deletes exactly this new resource; for when it cannot be recorded. Never fails. */
  readonly discard: Effect.Effect<void>;
}

export interface SizeRequest {
  readonly vcpus?: number;
  readonly memoryMib?: number;
  readonly diskMib?: number;
}

export interface CreateVmSpec {
  readonly cmuxId: VmId;
  readonly idleTimeoutSeconds: number;
  readonly maxRunSeconds?: number;
  readonly autoDeleteSeconds?: number;
  /** Without a source snapshot: the size to boot; picks the base image size. */
  readonly size?: SizeRequest;
  /** Deployment name (staging, production, ...), tagged on the upstream VM. */
  readonly environment: string;
}

/**
 * The provider's public base images (Ubuntu 24.04 LTS), smallest first. The
 * provider default is the 4 vCPU one. Sizes are grow-only, so a create boots
 * the largest base that fits inside the request and grows from there.
 */
const BASE_IMAGES: ReadonlyArray<{ readonly snapshot: string | null; readonly vcpus: number; readonly memoryMib: number; readonly diskMib: number }> = [
  { snapshot: "freestyle/ubuntu-sm", vcpus: 2, memoryMib: 4096, diskMib: 16384 },
  { snapshot: null, vcpus: 4, memoryMib: 8192, diskMib: 32768 },
  { snapshot: "freestyle/ubuntu-lg", vcpus: 8, memoryMib: 16384, diskMib: 65536 },
  { snapshot: "freestyle/ubuntu-xl", vcpus: 16, memoryMib: 32768, diskMib: 131072 },
  { snapshot: "freestyle/ubuntu-2xl", vcpus: 32, memoryMib: 65536, diskMib: 131072 },
];

/** The base image to boot for `size`: the largest that fits within every requested axis (the smallest when none does). */
export const baseImageFor = (size: SizeRequest | undefined): string | null => {
  if (size === undefined || (size.vcpus === undefined && size.memoryMib === undefined && size.diskMib === undefined)) return null;
  const fits = BASE_IMAGES.filter(
    (image) =>
      (size.vcpus === undefined || image.vcpus <= size.vcpus) &&
      (size.memoryMib === undefined || image.memoryMib <= size.memoryMib) &&
      (size.diskMib === undefined || image.diskMib <= size.diskMib),
  );
  return (fits.at(-1) ?? BASE_IMAGES[0])?.snapshot ?? null;
};

export interface ExecSpec {
  readonly command: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly stdinBase64?: string;
  readonly timeoutMs?: number;
  readonly user?: string;
}

export interface FileRead {
  readonly status: 200 | 206;
  readonly contentRange: string | null;
  readonly contentLength: string | null;
  readonly body: ReadableStream<Uint8Array>;
}

export interface FileEntryRecord {
  readonly name: string;
  readonly kind: string;
}

type Owns<C, R> = TenantOwnsResource<C, R>;
type Write<C> = KeyHasScope<C, "vm:write">;

export interface UpstreamClientService {
  readonly getVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:read"> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Reads a VM's state on the way to changing it. */
  readonly getVmForWrite: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> },
  ) => Effect.Effect<UpstreamVm, UpstreamError>;
  /**
   * Boots a new VM for the caller's tenant. Its upstream name and metadata
   * carry the tenant id and the cmux id. With `source`, it boots from that
   * snapshot of the tenant's.
   */
  readonly createVm: <C, S = never>(
    caller: Named<C, Principal>,
    spec: CreateVmSpec,
    proofs: {
      readonly mayCreate: TenantMayCreate<C, "vm">;
      readonly scope: Write<C>;
      readonly source?: { readonly snapshot: Named<S, SnapshotId>; readonly owns: Owns<C, S> };
    },
  ) => Effect.Effect<
    CreatedResource & {
      readonly vm: UpstreamVm;
      /** Grows exactly this new VM to `size` on the axes where it is smaller. */
      readonly grow: (size: SizeRequest) => Effect.Effect<UpstreamVm, UpstreamError>;
    },
    UpstreamError
  >;
  readonly startVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<UpstreamVm, UpstreamError>;
  readonly pauseVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<UpstreamVm, UpstreamError>;
  /** Shuts the guest down from inside (the provider has no stop operation). */
  readonly shutdownVm: <C, R>(vm: Named<R, VmId>, proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> }) => Effect.Effect<void, UpstreamError>;
  /** Deletes the VM; "gone" when the provider no longer had it. */
  readonly deleteVm: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C> },
  ) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  /** Snapshots a VM for a fork. The snapshot's upstream name carries the tenant id and its cmux id. */
  readonly snapshotForFork: <C, R>(
    caller: Named<C, Principal>,
    vm: Named<R, VmId>,
    spec: { readonly cmuxId: SnapshotId },
    proofs: { readonly owns: Owns<C, R>; readonly scope: Write<C>; readonly mayCreate: TenantMayCreate<C, "vm"> },
  ) => Effect.Effect<CreatedResource, UpstreamError>;
  /** Deletes a snapshot; "gone" when the provider no longer had it. */
  readonly deleteSnapshot: <C, S>(
    snapshot: Named<S, SnapshotId>,
    proofs: { readonly owns: Owns<C, S>; readonly scope: Write<C> | KeyHasScope<C, "snapshot:*"> },
  ) => Effect.Effect<"deleted" | "gone", UpstreamError>;
  /** Runs a command; the body is the public ExecResult, streamed as it arrives. */
  readonly exec: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:exec"> },
    spec: ExecSpec,
  ) => Effect.Effect<ReadableStream<Uint8Array>, UpstreamError>;
  readonly readFile: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    path: string,
    range: string | undefined,
  ) => Effect.Effect<FileRead, UpstreamError>;
  readonly writeFile: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    file: { readonly path: string; readonly mode: number | undefined; readonly body: ReadableStream<Uint8Array>; readonly length: number },
  ) => Effect.Effect<void, UpstreamError>;
  readonly listFiles: <C, R>(
    vm: Named<R, VmId>,
    proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
    path: string,
  ) => Effect.Effect<ReadonlyArray<FileEntryRecord>, UpstreamError>;
}

export class UpstreamClient extends Context.Tag("cmux-vm/UpstreamClient")<UpstreamClient, UpstreamClientService>() {}

export interface UpstreamConfig {
  readonly baseUrl: string;
  readonly apiKey: Redacted.Redacted<string>;
  readonly fetch?: (request: Request) => Promise<Response>;
  readonly timeoutMs?: number;
}

const MAX_RESPONSE_BYTES = 1024 * 1024;
/** Booting, snapshotting and shutting down can take longer than a read. */
const SLOW_TIMEOUT_MS = 120_000;
/** File transfers stream; this bounds a stuck one. */
const TRANSFER_TIMEOUT_MS = 15 * 60_000;
const DEFAULT_EXEC_TIMEOUT_MS = 30_000;
/** Snapshots taken for a fork are deleted after a successful fork; this is the backstop for failed ones. */
const FORK_SNAPSHOT_AUTO_DELETE_SECONDS = 24 * 60 * 60;
/** Provider metadata values are at most 63 characters. */
const METADATA_VALUE_MAX = 63;

interface SendInit {
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  readonly query?: Readonly<Record<string, string>>;
  readonly json?: unknown;
  readonly body?: { readonly stream: ReadableStream<Uint8Array>; readonly length: number };
  readonly headers?: Readonly<Record<string, string>>;
  readonly timeoutMs?: number;
}

/** The provider's display name for a resource: who owns it and which public id it is. */
const upstreamName = (tenantId: string, cmuxId: string) => `cmux ${tenantId} ${cmuxId}`;

export function makeUpstreamClient(config: UpstreamConfig): UpstreamClientService {
  const base = new URL(config.baseUrl);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash) {
    throw new Error("upstream base URL must be a bare HTTPS origin");
  }
  const sendRequest = config.fetch ?? ((request: Request) => fetch(request));
  const defaultTimeoutMs = config.timeoutMs ?? 10_000;

  /** Sends one request. Resolves with a 2xx response (body unread); any other status is an UpstreamError. */
  const send = (operation: string, path: string, init: SendInit): Effect.Effect<Response, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const url = new URL(path, base);
        for (const [key, value] of Object.entries(init.query ?? {})) url.searchParams.set(key, value);
        const headers: Record<string, string> = {
          ...init.headers,
          authorization: `Bearer ${Redacted.value(config.apiKey)}`,
          accept: "application/json",
        };
        let body: BodyInit | null = null;
        if (init.json !== undefined) {
          headers["content-type"] = "application/json";
          body = JSON.stringify(init.json);
        } else if (init.body !== undefined) {
          headers["content-type"] = "application/octet-stream";
          const sized = new FixedLengthStream(init.body.length);
          void init.body.stream.pipeTo(sized.writable).catch(() => undefined);
          body = sized.readable;
        }
        const request = new Request(url, {
          method: init.method,
          headers,
          body,
          redirect: "manual",
          signal: AbortSignal.timeout(init.timeoutMs ?? defaultTimeoutMs),
        });
        const response = await sendRequest(request);
        if (response.status < 200 || response.status > 299) {
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        return { ok: true as const, response };
      },
      catch: () => new UpstreamError({ operation, status: null }),
    }).pipe(
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.response) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
    );

  const json = <A, I>(operation: string, schema: Schema.Schema<A, I>) => (response: Response): Effect.Effect<A, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const text = await response.text();
        if (text.length > MAX_RESPONSE_BYTES) throw new Error("response too large");
        const parsed: unknown = JSON.parse(text);
        return parsed;
      },
      catch: () => new UpstreamError({ operation, status: response.status }),
    }).pipe(
      Effect.flatMap(Schema.decodeUnknown(schema)),
      Effect.mapError((error) => (error instanceof UpstreamError ? error : new UpstreamError({ operation, status: response.status }))),
    );

  const drain = (response: Response) => Effect.promise(async () => void (await response.body?.cancel()));

  const vmPath = (id: UpstreamId, suffix = "") => `/v5/vms/${encodeURIComponent(id)}${suffix}`;

  const getVmById = (operation: string, id: UpstreamId) =>
    send(operation, vmPath(id), { method: "GET" }).pipe(Effect.flatMap(json(operation, UpstreamVm)));

  const vmAction = (operation: string, id: UpstreamId, action: string) =>
    send(operation, vmPath(id, `/${action}`), { method: "POST", timeoutMs: SLOW_TIMEOUT_MS }).pipe(
      Effect.flatMap(json(operation, UpstreamVm)),
    );

  const deleteById = (operation: string, path: string): Effect.Effect<"deleted" | "gone", UpstreamError> =>
    send(operation, path, { method: "DELETE", timeoutMs: SLOW_TIMEOUT_MS }).pipe(
      Effect.flatMap(drain),
      Effect.as("deleted" as const),
      Effect.catchIf(
        (error) => error.status === 404,
        () => Effect.succeed("gone" as const),
      ),
    );

  /** Resizes on the axes where `size` exceeds `current`; no call when none does. */
  const growVm = (id: UpstreamId, current: UpstreamVm, size: SizeRequest): Effect.Effect<UpstreamVm, UpstreamError> => {
    const body: Record<string, number> = {};
    if (size.vcpus !== undefined && size.vcpus > current.resources.cpu) body["cpu"] = size.vcpus;
    if (size.memoryMib !== undefined && size.memoryMib > current.resources.memory) body["memory"] = size.memoryMib;
    if (size.diskMib !== undefined && size.diskMib > current.resources.storage) body["storage"] = size.diskMib;
    if (Object.keys(body).length === 0) return Effect.succeed(current);
    return send("resizeVm", vmPath(id, "/resize"), { method: "POST", json: body, timeoutMs: SLOW_TIMEOUT_MS }).pipe(
      Effect.flatMap(json("resizeVm", UpstreamVm)),
    );
  };

  const discardVm = (id: UpstreamId) => deleteById("discardVm", vmPath(id)).pipe(Effect.ignore);
  const discardSnapshot = (id: UpstreamId) => deleteById("discardSnapshot", `/v5/snapshots/${encodeURIComponent(id)}`).pipe(Effect.ignore);

  return {
    getVm: (_vm, { owns }) => getVmById("getVm", owns.upstreamId),

    getVmForWrite: (_vm, { owns }) => getVmById("getVm", owns.upstreamId),

    createVm: (caller, spec, { source }) => {
      const tenantId = caller.value.tenantId;
      const metadata: Record<string, string> = { cmux_id: spec.cmuxId, cmux_env: spec.environment };
      // Stack team ids fit; the display name carries the tenant id regardless.
      if (tenantId.length <= METADATA_VALUE_MAX) metadata["cmux_tenant"] = tenantId;
      const body = {
        displayName: upstreamName(tenantId, spec.cmuxId),
        idleTimeoutSeconds: spec.idleTimeoutSeconds,
        ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
        ...(spec.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: spec.autoDeleteSeconds }),
        metadata,
        // Nothing implicit: no inbound and no outbound rules until networking endpoints add them.
        firewall: { rules: [] },
        ...(source !== undefined
          ? { snapshotId: source.owns.upstreamId }
          : baseImageFor(spec.size) === null
            ? {}
            : { snapshotId: baseImageFor(spec.size) }),
      };
      return send("createVm", "/v5/vms", { method: "POST", json: body, timeoutMs: SLOW_TIMEOUT_MS }).pipe(
        Effect.flatMap(json("createVm", CreatedVm)),
        Effect.map(({ id, ...vm }) => ({ upstreamId: id, vm, discard: discardVm(id), grow: (size: SizeRequest) => growVm(id, vm, size) })),
      );
    },

    startVm: (_vm, { owns }) => vmAction("startVm", owns.upstreamId, "start"),

    pauseVm: (_vm, { owns }) => vmAction("pauseVm", owns.upstreamId, "pause"),

    shutdownVm: (_vm, { owns }) =>
      send("stopVm", vmPath(owns.upstreamId, "/exec-await"), {
        method: "POST",
        json: { command: "poweroff", timeoutMs: 10_000 },
        timeoutMs: SLOW_TIMEOUT_MS,
      }).pipe(
        Effect.flatMap(drain),
        // The guest can go away before it answers; the provider reports that as a 409.
        Effect.catchIf(
          (error) => error.status === 409,
          () => Effect.void,
        ),
      ),

    deleteVm: (_vm, { owns }) => deleteById("deleteVm", vmPath(owns.upstreamId)),

    snapshotForFork: (caller, _vm, spec, { owns }) =>
      send("snapshotVm", vmPath(owns.upstreamId, "/snapshot"), {
        method: "POST",
        json: { displayName: upstreamName(caller.value.tenantId, spec.cmuxId), autoDeleteSeconds: FORK_SNAPSHOT_AUTO_DELETE_SECONDS },
        timeoutMs: SLOW_TIMEOUT_MS,
      }).pipe(
        Effect.flatMap(json("snapshotVm", CreatedSnapshot)),
        Effect.map(({ snapshotId }) => ({ upstreamId: snapshotId, discard: discardSnapshot(snapshotId) })),
      ),

    deleteSnapshot: (_snapshot, { owns }) => deleteById("deleteSnapshot", `/v5/snapshots/${encodeURIComponent(owns.upstreamId)}`),

    exec: (_vm, { owns }, spec) =>
      send("execVm", vmPath(owns.upstreamId, "/exec-await"), {
        method: "POST",
        json: {
          command: spec.command,
          ...(spec.env === undefined ? {} : { env: spec.env }),
          ...(spec.stdinBase64 === undefined ? {} : { stdin: spec.stdinBase64 }),
          ...(spec.timeoutMs === undefined ? {} : { timeoutMs: spec.timeoutMs }),
          ...(spec.user === undefined ? {} : { linuxUser: spec.user }),
        },
        timeoutMs: (spec.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS) + 30_000,
      }).pipe(
        Effect.flatMap((response) =>
          response.body === null
            ? Effect.fail(new UpstreamError({ operation: "execVm", status: response.status }))
            : Effect.succeed(response.body.pipeThrough(execResultStream())),
        ),
      ),

    readFile: (_vm, { owns }, path, range) =>
      send("readFile", vmPath(owns.upstreamId, "/fs/read"), {
        method: "GET",
        query: { path },
        ...(range === undefined ? {} : { headers: { range } }),
        timeoutMs: TRANSFER_TIMEOUT_MS,
      }).pipe(
        Effect.flatMap((response) => {
          if (response.body === null) return Effect.fail(new UpstreamError({ operation: "readFile", status: response.status }));
          if (response.status !== 200 && response.status !== 206) {
            return drain(response).pipe(Effect.zipRight(Effect.fail(new UpstreamError({ operation: "readFile", status: response.status }))));
          }
          return Effect.succeed<FileRead>({
            status: response.status === 206 ? 206 : 200,
            contentRange: response.headers.get("content-range"),
            contentLength: response.headers.get("content-length"),
            body: response.body,
          });
        }),
      ),

    writeFile: (_vm, { owns }, file) =>
      send("writeFile", vmPath(owns.upstreamId, "/fs/write"), {
        method: "PUT",
        query: file.mode === undefined ? { path: file.path } : { path: file.path, mode: String(file.mode) },
        body: { stream: file.body, length: file.length },
        timeoutMs: TRANSFER_TIMEOUT_MS,
      }).pipe(Effect.flatMap(drain)),

    listFiles: (_vm, { owns }, path) =>
      send("listFiles", vmPath(owns.upstreamId, "/fs/dir"), { method: "GET", query: { path } }).pipe(
        Effect.flatMap(json("listFiles", DirListing)),
        Effect.map((listing) => listing.entries),
      ),
  };
}
