import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Redacted from "effect/Redacted";

import { cloudDbConfig, cloudDbConfigKey } from "../../db/config";
import { makeDatabaseRuntime } from "../../db/effect";
import { isHangReportError, storageUnavailable, type HangReportStorageUnavailable } from "./errors";
import { HangReportsRepository, HangReportsRepositoryLive } from "./repository";

const POOL_MAX = 2;

type Runtime = ReturnType<typeof makeDatabaseRuntime>;

const globals = globalThis as typeof globalThis & {
  __cmuxHangReportsEffectDatabase?: { key: string; runtime: Runtime };
};

/**
 * One small Effect-owned pool per server instance for hang report ingest and
 * retention. PlanetScale only: `CMUX_DB_DRIVER=url` with `DATABASE_URL`.
 */
function hangReportsDatabaseRuntime(): Runtime {
  const config = cloudDbConfig();
  if (config.driver !== "url") {
    throw new Error("hang reports need CMUX_DB_DRIVER=url with a PlanetScale DATABASE_URL");
  }
  const key = `${cloudDbConfigKey(config)}:hang-reports:${POOL_MAX}`;
  const current = globals.__cmuxHangReportsEffectDatabase;
  if (current?.key === key) return current.runtime;
  const runtime = makeDatabaseRuntime({
    url: Redacted.make(config.url),
    maxConnections: POOL_MAX,
    applicationName: "cmux-hang-reports",
  });
  globals.__cmuxHangReportsEffectDatabase = { key, runtime };
  if (current) void current.runtime.dispose();
  return runtime;
}

/**
 * Run a hang report program against Postgres. Configuration, connection and
 * pool failures become ``HangReportStorageUnavailable`` (tag and SQLSTATE
 * only); domain failures pass through.
 */
export async function runWithHangReportsDatabase<A, E>(
  program: Effect.Effect<A, E, HangReportsRepository>,
): Promise<Exit.Exit<A, E | HangReportStorageUnavailable>> {
  let runtime: Runtime;
  try {
    runtime = hangReportsDatabaseRuntime();
  } catch (cause) {
    return Exit.fail(storageUnavailable("connect", cause));
  }
  const exit = await runtime.runPromiseExit(program.pipe(Effect.provide(HangReportsRepositoryLive)));
  return Exit.mapError(exit, (error) =>
    isHangReportError(error) ? error as E | HangReportStorageUnavailable : storageUnavailable("connect", error));
}
