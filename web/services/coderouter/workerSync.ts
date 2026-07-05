import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { CoderouterConfigurationError, CoderouterWorkerSyncError } from "./errors";
import type { PoolConfig, SeedOauth } from "./types";

export type CoderouterWorkerSyncShape = {
  readonly syncPool: (config: PoolConfig) => Effect.Effect<void, CoderouterConfigurationError | CoderouterWorkerSyncError>;
  readonly seedOauth: (poolName: string, seed: SeedOauth) => Effect.Effect<void, CoderouterConfigurationError | CoderouterWorkerSyncError>;
};

export class CoderouterWorkerSync extends Context.Tag("cmux/CoderouterWorkerSync")<
  CoderouterWorkerSync,
  CoderouterWorkerSyncShape
>() {}

export const CoderouterWorkerSyncLive = Layer.succeed(
  CoderouterWorkerSync,
  makeCoderouterWorkerSync(process.env, fetch),
);

export function makeCoderouterWorkerSync(
  env: Record<string, string | undefined>,
  fetchFn: typeof fetch,
): CoderouterWorkerSyncShape {
  return {
    syncPool: (config) =>
      postWorker({
        env,
        fetchFn,
        operation: "syncPool",
        path: `/internal/pools/${encodeURIComponent(config.poolId)}/sync`,
        body: config,
      }),

    seedOauth: (poolName, seed) =>
      postWorker({
        env,
        fetchFn,
        operation: "seedOauth",
        path: `/internal/pools/${encodeURIComponent(poolName)}/seed-oauth`,
        body: seed,
      }),
  };
}

export function noOpCoderouterWorkerSync(): CoderouterWorkerSyncShape {
  return {
    syncPool: () => Effect.void,
    seedOauth: () => Effect.void,
  };
}

function postWorker(input: {
  readonly env: Record<string, string | undefined>;
  readonly fetchFn: typeof fetch;
  readonly operation: string;
  readonly path: string;
  readonly body: unknown;
}): Effect.Effect<void, CoderouterConfigurationError | CoderouterWorkerSyncError> {
  return Effect.tryPromise({
    try: async () => {
      const base = input.env.CODEROUTER_WORKER_BASE_URL?.trim();
      const token = input.env.CODEROUTER_INTERNAL_TOKEN?.trim();
      if (!base) {
        throw new CoderouterConfigurationError(input.operation, "CODEROUTER_WORKER_BASE_URL is not configured.");
      }
      if (!token) {
        throw new CoderouterConfigurationError(input.operation, "CODEROUTER_INTERNAL_TOKEN is not configured.");
      }
      const response = await input.fetchFn(new URL(input.path, base), {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(input.body),
      });
      if (!response.ok) {
        throw new CoderouterWorkerSyncError(input.operation, response.status);
      }
    },
    catch: (cause) => {
      if (cause instanceof CoderouterConfigurationError || cause instanceof CoderouterWorkerSyncError) return cause;
      return new CoderouterWorkerSyncError(input.operation, null, cause);
    },
  });
}
