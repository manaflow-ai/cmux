/**
 * Composition: the API, its handlers, and the service Layers they need. The
 * Worker entry (index.ts) supplies live Layers; tests supply fakes.
 */
import { HttpApiBuilder, HttpServer, type HttpApp } from "@effect/platform";
import { Effect, Layer, ManagedRuntime, type Redacted } from "effect";
import { CmuxVmApi } from "./api.ts";
import { authenticationLayer } from "./auth/middleware.ts";
import type { SessionVerifier, TeamMembership } from "./auth/credentials.ts";
import type { ApiKeyStore, AuditStore, OwnershipStore } from "./db/stores.ts";
import { execHandlers } from "./handlers/exec.ts";
import { filesHandlers } from "./handlers/files.ts";
import { healthHandlers } from "./handlers/health.ts";
import { vmsHandlers } from "./handlers/vms.ts";
import type { TenantLimits } from "./limits/service.ts";
import type { TenantPolicy } from "./policy.ts";
import type { Entitlements } from "./proofs/tenant-may-create.ts";
import type { UpstreamClient } from "./upstream/client.ts";
import { snapshotsHandlers } from "./handlers/snapshots.ts";
import { terminalsHandlers } from "./handlers/terminals.ts";
import { apiKeysHandlers } from "./handlers/api-keys.ts";
import type { TeamAdmin } from "./auth/team-admin.ts";
import type { ApiKeyAdminStore } from "./db/api-keys.ts";
import type { SnapshotStore } from "./db/snapshots.ts";
import type { UpstreamSnapshots } from "./upstream/snapshots.ts";
import type { UpstreamTerminals } from "./upstream/terminals.ts";
import { meshDeviceHandlers, meshEnrollHandlers, meshHandlers } from "./handlers/mesh.ts";
import type { MeshStore } from "./db/mesh.ts";
import type { MeshConfig } from "./mesh/config.ts";
import type { UpstreamMesh } from "./upstream/mesh.ts";
import type { MembershipCache } from "./auth/membership-cache.ts";
import type { WebhookDeliveryStore } from "./db/identity.ts";
import { handleStackWebhook, STACK_WEBHOOK_PATH } from "./handlers/stack-webhook.ts";

export type Services =
  | OwnershipStore
  | ApiKeyStore
  | AuditStore
  | UpstreamClient
  | SessionVerifier
  | TeamMembership
  | TenantLimits
  | TenantPolicy
  | Entitlements
  | S3aServices
  | MeshServices;

/** Mesh experiment (cx-0op); the membership cache and webhook deliveries are M4 (cx-0op.6, cx-0op.7). */
type MeshServices = MeshStore | UpstreamMesh | MeshConfig | MembershipCache | WebhookDeliveryStore;

/** Snapshots and terminals (slice S3a). */
type S3aServices = SnapshotStore | UpstreamSnapshots | UpstreamTerminals | ApiKeyAdminStore | TeamAdmin;

/** JSON request bodies above this are refused with 413 before any handler runs. File uploads have their own limit. */
export const MAX_JSON_BODY_BYTES = 2 * 1024 * 1024;

const UPLOAD_PATH = /^\/v1\/vms\/[^/]+\/files\/content$/u;

const tooLarge = () =>
  Response.json(
    { _tag: "PayloadTooLarge", message: `Request bodies are limited to ${MAX_JSON_BODY_BYTES} bytes`, maxBytes: MAX_JSON_BODY_BYTES },
    { status: 413 },
  );

/** Caps a body without a trustworthy length: the stream errors past `max` bytes. */
const capped = (body: ReadableStream<Uint8Array>, max: number) => {
  let seen = 0;
  return body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        seen += chunk.byteLength;
        if (seen > max) controller.error(new Error("request body too large"));
        else controller.enqueue(chunk);
      },
    }),
  );
};

export interface WebHandlerOptions {
  /** Wraps every request's Effect, e.g. to share one database connection per request. */
  readonly perRequest?: (app: HttpApp.Default) => HttpApp.Default;
  /** The same wrapper for the Stack webhook, which runs outside the HTTP API. */
  readonly perWebhook?: <A, E, R>(effect: Effect.Effect<A, E, R>) => Effect.Effect<A, E, R>;
  /** The Stack webhook signing secret (Worker secret STACK_WEBHOOK_SECRET); absent: the webhook answers 503. */
  readonly stackWebhookSecret?: Redacted.Redacted<string>;
}

export const makeWebHandler = (services: Layer.Layer<Services>, options: WebHandlerOptions = {}) => {
  const authenticated = <A, E, R>(group: Layer.Layer<A, E, R>) => group.pipe(Layer.provide(authenticationLayer));
  const api = HttpApiBuilder.api(CmuxVmApi).pipe(
    Layer.provide(healthHandlers),
    Layer.provide(authenticated(vmsHandlers)),
    Layer.provide(authenticated(execHandlers)),
    Layer.provide(authenticated(filesHandlers)),
    Layer.provide(authenticated(snapshotsHandlers)),
    Layer.provide(authenticated(terminalsHandlers)),
    Layer.provide(authenticated(apiKeysHandlers)),
    Layer.provide(authenticated(meshHandlers)),
    // The one-time enrollment code is the credential (mesh M2, cx-0op.4).
    Layer.provide(meshEnrollHandlers),
    // The device's install-key signature is the credential (mesh M3, cx-0op.5).
    Layer.provide(meshDeviceHandlers),
    Layer.provide(services),
  );
  const perRequest = options.perRequest;
  const web = HttpApiBuilder.toWebHandler(
    Layer.mergeAll(api, HttpServer.layerContext),
    perRequest === undefined ? {} : { middleware: (app) => perRequest(app) },
  );
  const runtime = ManagedRuntime.make(services);
  const perWebhook = options.perWebhook ?? (<A, E, R>(effect: Effect.Effect<A, E, R>) => effect);
  const webhook = (request: Request): Promise<Response> =>
    runtime.runPromise(perWebhook(handleStackWebhook(request, options.stackWebhookSecret))).catch(() =>
      Response.json({ _tag: "ServiceUnavailable", message: "Webhook failed; retry" }, { status: 503 }),
    );
  return {
    dispose: async () => {
      await web.dispose();
      await runtime.dispose();
    },
    /** Refuses oversized JSON bodies, then serves the API. Uploads stream untouched to their handler. */
    handler: (request: Request): Promise<Response> => {
      if (new URL(request.url).pathname === STACK_WEBHOOK_PATH) return webhook(request);
      if (request.body === null || UPLOAD_PATH.test(new URL(request.url).pathname)) return web.handler(request);
      const declared = request.headers.get("content-length");
      if (declared !== null && Number(declared) > MAX_JSON_BODY_BYTES) return Promise.resolve(tooLarge());
      const method = request.method;
      return web.handler(new Request(request.url, { method, headers: request.headers, body: capped(request.body, MAX_JSON_BODY_BYTES) }));
    },
  };
};
