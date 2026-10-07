/**
 * Composition: the API, its handlers, and the service Layers they need. The
 * Worker entry (index.ts) supplies live Layers; tests supply fakes.
 */
import { HttpApiBuilder, HttpServer } from "@effect/platform";
import { Layer } from "effect";
import { CmuxVmApi } from "./api.ts";
import { authenticationLayer } from "./auth/middleware.ts";
import type { SessionVerifier, TeamMembership } from "./auth/credentials.ts";
import type { ApiKeyStore, OwnershipStore } from "./db/stores.ts";
import { healthHandlers } from "./handlers/health.ts";
import { vmsHandlers } from "./handlers/vms.ts";
import type { UpstreamClient } from "./upstream/client.ts";

export type Services = OwnershipStore | ApiKeyStore | UpstreamClient | SessionVerifier | TeamMembership;

export const makeWebHandler = (services: Layer.Layer<Services>) => {
  const api = HttpApiBuilder.api(CmuxVmApi).pipe(
    Layer.provide(healthHandlers),
    Layer.provide(vmsHandlers.pipe(Layer.provide(authenticationLayer))),
    Layer.provide(services),
  );
  return HttpApiBuilder.toWebHandler(Layer.mergeAll(api, HttpServer.layerContext));
};
