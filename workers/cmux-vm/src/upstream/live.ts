/**
 * The upstream client implementation: the only module that sends the provider
 * key. Every method demands gdp-ts proofs about its exact named arguments, and
 * the upstream id of an existing resource comes only from a minted
 * TenantOwnsResource proof (`upstreamIdOf`). Lint (oxlint.config.ts,
 * no-restricted-imports) lets only src/upstream/, src/proofs/ and the
 * composition root src/index.ts import this module.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import { makeUpstreamHttp } from "./live-http.ts";
import { makeHttpsProxies } from "./live-https-proxies.ts";
import { makePublicEgress } from "./live-public-egress.ts";
import { makeRetireVm } from "./live-retire.ts";
import { makeClientSessions } from "./live-client-sessions.ts";
import { makeStatFile } from "./live-file-stat.ts";
import { vmInstanceIdentity } from "./live-identity.ts";
import { admitSend, makeDurableCreate, makeRecoverCreation, makeInspectCancellation, makeDeleteCancellation } from "./live-create.ts";
import { UpstreamId } from "../lib/ids.ts";
import type { Environment } from "../policy.ts";
import type { CreateAdmissionClient } from "../limits/create-admission.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import {
  UpstreamClient,
  resourceFloorsReached,
  UpstreamError,
  UpstreamVm,
  type FileRead,
  type SizeRequest,
  type UpstreamClientService,
} from "./client.ts";
import { execResultStream } from "./exec-stream.ts";
import { awaitBackground, BACKGROUND_AFTER_HEADER, BACKGROUND_AFTER_SECS, DEFAULT_BACKGROUND_POLL_MS } from "./live-background.ts";
import { timedUpstream, timedUpstreamBody } from "./timing.ts";

const DirListing = Schema.Struct({
  entries: Schema.Array(Schema.Struct({ name: Schema.String, kind: Schema.String })),
});

/** The upstream id a minted proof stands for; a proof not minted in src/proofs is a defect. */
const idOf = <C, R>(proof: TenantOwnsResource<C, R>): Effect.Effect<UpstreamId> => Effect.sync(() => upstreamIdOf(proof));

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

export interface UpstreamConfig {
  readonly baseUrl: string;
  readonly apiKey: Redacted.Redacted<string>;
  /** Prefixes every upstream name (src/upstream/naming.ts). */
  readonly environment: Environment;
  readonly fetch?: (request: Request) => Promise<Response>;
  readonly timeoutMs?: number;
  /** How often a background request's stored result is polled (live-background.ts); tests set 1. */
  readonly backgroundPollMs?: number;
  /** How long background polls may fail before the request is unanswered (tests set it lower). */
  readonly backgroundOutageMs?: number;
  /** How often a disk grow re-reads a VM that is still starting (GROW_START_POLLS times); tests set 1. */
  readonly startPollMs?: number;
  /** The environment's provider create queue (limits/create-admission.ts); none sends every create at once. */
  readonly createAdmission?: CreateAdmissionClient;
}

/**
 * A disk grow needs a running VM. One asked of a VM the provider still reports "starting" (a
 * Cloud chat grows its disk right after the machine first answers, while the provider's state can
 * lag: production 2026-11-26 01:08-01:29Z, 18 such 409s) waits for it, at most this many reads.
 */
const GROW_START_POLLS = 30;
const DEFAULT_START_POLL_MS = 2_000;

const MAX_RESPONSE_BYTES = 1024 * 1024;
/** Booting, snapshotting and shutting down can take longer than a read. */
const SLOW_TIMEOUT_MS = 120_000;
/** File transfers stream; this bounds a stuck one. */
const TRANSFER_TIMEOUT_MS = 15 * 60_000;
const DEFAULT_EXEC_TIMEOUT_MS = 30_000;
/** Snapshots taken for a fork are deleted after a successful fork; this is the backstop for failed ones. */
/** Provider metadata values are at most 63 characters. */

interface SendInit {
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  readonly query?: Readonly<Record<string, string>>;
  readonly json?: unknown;
  readonly body?: { readonly stream: ReadableStream<Uint8Array>; readonly length: number };
  readonly headers?: Readonly<Record<string, string>>;
  readonly timeoutMs?: number;
}

/** The provider's display name for a resource: who owns it and which public id it is. */
/** Logs which provider operation failed and its HTTP status (or "none"); never ids, bodies or the key. */
const logUpstreamFailure = (error: UpstreamError) =>
  Effect.logWarning("cmux-vm upstream call failed").pipe(
    Effect.annotateLogs({ operation: error.operation, status: error.status === null ? "none" : String(error.status) }),
  );


export function makeUpstreamClient(config: UpstreamConfig): UpstreamClientService {
  const base = new URL(config.baseUrl);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || base.pathname !== "/") {
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
      timedUpstream,
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.response) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
      Effect.tapError(logUpstreamFailure),
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
      // `send` timed the call to its answer headers; the body comes after, still the provider's time.
      timedUpstreamBody,
      Effect.flatMap(Schema.decodeUnknown(schema)),
      Effect.mapError((error) => (error instanceof UpstreamError ? error : new UpstreamError({ operation, status: response.status }))),
      Effect.tapError(() =>
        Effect.logWarning("cmux-vm upstream response unreadable").pipe(Effect.annotateLogs({ operation, status: String(response.status) })),
      ),
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


  return {
    ...vmInstanceIdentity,
    resizeVm: (_vm, { owns }, size) => Effect.flatMap(idOf(owns), (id) => Effect.gen(function* () {
      let current = yield* getVmById("resizeVm", id);
      const growsDisk = size.diskMib !== undefined && size.diskMib > current.resources.storage;
      for (let read = 0; growsDisk && current.state === "starting" && read < GROW_START_POLLS; read += 1) {
        yield* Effect.sleep(config.startPollMs ?? DEFAULT_START_POLL_MS);
        current = yield* getVmById("resizeVm", id);
      }
      if (size.diskMib !== undefined && size.diskMib > current.resources.storage && current.state !== "running") {
        return yield* Effect.fail(new UpstreamError({ operation: "resizeVm", status: 409 }));
      }
      return yield* growVm(id, current, size).pipe(
        Effect.flatMap((grown) => resourceFloorsReached(grown, size) ? Effect.succeed(grown) : Effect.fail(new UpstreamError({ operation: "resizeVm", status: null }))),
        // An error can follow an applied or partially applied resize. Confirm before reporting failure.
        Effect.catchAll((error) => getVmById("resizeVm", id).pipe(
          Effect.catchAll(() => Effect.fail(error)),
          Effect.flatMap((latest) => resourceFloorsReached(latest, size) ? Effect.succeed(latest) : Effect.fail(error)),
        )),
      );
    })),
    ...makeHttpsProxies(makeUpstreamHttp(config)),
    ...makePublicEgress(makeUpstreamHttp(config)),
    ...makeRetireVm(makeUpstreamHttp(config)),
    ...makeClientSessions(makeUpstreamHttp(config), base.origin),
    ...makeStatFile(makeUpstreamHttp(config)),
    getVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => getVmById("getVm", id)),

    getVmForWrite: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => getVmById("getVm", id)),

    recoverCreation: makeRecoverCreation(config),
    inspectCancellingCreation: makeInspectCancellation(config),
    deleteCancellingCreation: makeDeleteCancellation(config),
    createVm: makeDurableCreate(config, baseImageFor),

    startVm: (_vm, { owns }, priority) => Effect.gen(function* () {
      const id = yield* idOf(owns);
      const release = yield* admitSend(config.createAdmission, `start:${crypto.randomUUID()}`, undefined, priority?.background === true, priority?.tenant);
      return yield* vmAction("startVm", id, "start").pipe(Effect.ensuring(release));
    }),

    pauseVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => vmAction("pauseVm", id, "pause")),

    shutdownVm: (_vm, { owns }) =>
      Effect.flatMap(idOf(owns), (id) => send("stopVm", vmPath(id, "/exec-await"), {
        method: "POST",
        // As root: the image's default user (ubuntu) is refused the poweroff, and the VM would run on.
        json: { command: "poweroff", timeoutMs: 10_000, linuxUser: "root" },
        timeoutMs: SLOW_TIMEOUT_MS,
      }).pipe(
        // A poweroff the guest answered with a failure did not stop it: never report that as a stop.
        Effect.flatMap((response) =>
          Effect.promise(() => response.json().catch(() => null)).pipe(
            Effect.flatMap((body: unknown) => {
              const status = typeof body === "object" && body !== null ? Reflect.get(body, "statusCode") : undefined;
              return typeof status === "number" && status !== 0
                ? Effect.fail(new UpstreamError({ operation: "stopVm", status: null }))
                : Effect.void;
            }),
          ),
        ),
        // The guest can go away before it answers; the provider reports that as a 409.
        Effect.catchIf(
          (error) => error.status === 409,
          () => Effect.void,
        ),
      )),

    deleteVm: (_vm, { owns }) => Effect.flatMap(idOf(owns), (id) => deleteById("deleteVm", vmPath(id))),

    deleteSnapshot: (_snapshot, { owns }) =>
      Effect.flatMap(idOf(owns), (id) => deleteById("deleteSnapshot", `/v5/snapshots/${encodeURIComponent(id)}`)),

    exec: (_vm, { owns }, spec) =>
      Effect.flatMap(idOf(owns), (id) => {
        const budgetMs = (spec.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS) + 30_000;
        const deadlineAt = Date.now() + budgetMs;
        return send("execVm", vmPath(id, "/exec-await"), {
          method: "POST",
          json: {
            command: spec.command,
            ...(spec.env === undefined ? {} : { env: spec.env }),
            ...(spec.stdinBase64 === undefined ? {} : { stdin: spec.stdinBase64 }),
            ...(spec.timeoutMs === undefined ? {} : { timeoutMs: spec.timeoutMs }),
            ...(spec.linuxUser === undefined ? {} : { linuxUser: spec.linuxUser }),
          },
          // Held open past about 120 s, the provider's edge cuts the call (524) while the command runs on: past
          // BACKGROUND_AFTER_SECS the provider answers 202 instead, and the stored result is polled (live-background.ts).
          headers: { [BACKGROUND_AFTER_HEADER]: String(BACKGROUND_AFTER_SECS) },
          timeoutMs: budgetMs,
        }).pipe(
          Effect.flatMap((response) =>
            response.status === 202
              ? awaitBackground(send, "execVm", response, base.origin, deadlineAt, config.backgroundPollMs ?? DEFAULT_BACKGROUND_POLL_MS, config.backgroundOutageMs)
              : Effect.succeed(response),
          ),
          Effect.flatMap((response) =>
            response.body === null
              ? Effect.fail(new UpstreamError({ operation: "execVm", status: response.status }))
              : Effect.succeed(response.body.pipeThrough(execResultStream())),
          ),
        );
      }),

    readFile: (_vm, { owns }, path, range) =>
      Effect.flatMap(idOf(owns), (id) => send("readFile", vmPath(id, "/fs/read"), {
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
      )),

    writeFile: (_vm, { owns }, file) =>
      Effect.flatMap(idOf(owns), (id) => send("writeFile", vmPath(id, "/fs/write"), {
        method: "PUT",
        query: file.mode === undefined ? { path: file.path } : { path: file.path, mode: String(file.mode) },
        body: { stream: file.body, length: file.length },
        timeoutMs: TRANSFER_TIMEOUT_MS,
      }).pipe(Effect.flatMap(drain))),

    listFiles: (_vm, { owns }, path) =>
      Effect.flatMap(idOf(owns), (id) =>
        send("listFiles", vmPath(id, "/fs/dir"), { method: "GET", query: { path } }).pipe(
          Effect.flatMap(json("listFiles", DirListing)),
          Effect.map((listing) => listing.entries),
        ),
      ),
  };
}

/**
 * The client's configuration from Worker configuration: every field as given, the key wrapped in Redacted at once.
 * The whole config is spread, never rebuilt field by field: the layer used to copy three named fields, so the
 * provider create queue src/index.ts passed (`createAdmission`, cmux#61073) never reached the client and staging sent
 * every create of a burst at once (2026-11-27 08:46Z, no vm_create line with admitWaitMs). The test harness builds
 * its client through this too, so a dropped field fails the Worker tests.
 */
export const upstreamConfigOf = (config: Omit<UpstreamConfig, "apiKey"> & { readonly apiKey: string }): UpstreamConfig => ({
  ...config,
  apiKey: Redacted.make(config.apiKey),
});

/** The live client from Worker configuration. Built eagerly, so a bad base URL throws here (src/index.ts answers 503). */
export const upstreamLayer = (config: Omit<UpstreamConfig, "apiKey"> & { readonly apiKey: string }): Layer.Layer<UpstreamClient> =>
  Layer.succeed(UpstreamClient, makeUpstreamClient(upstreamConfigOf(config)));
