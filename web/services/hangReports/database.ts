import { Signer } from "@aws-sdk/rds-signer";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Redacted from "effect/Redacted";

import { cloudDbConfig, cloudDbConfigKey } from "../../db/config";
import { makeDatabaseRuntime } from "../../db/effect";
import { HangReportStorageUnavailable, isHangReportError } from "./errors";
import { HangReportsRepository, HangReportsRepositoryLive } from "./repository";

const POOL_MAX = 2;

type Runtime = ReturnType<typeof makeDatabaseRuntime>;

const globals = globalThis as typeof globalThis & {
  __cmuxHangReportsEffectDatabase?: { key: string; runtime: Runtime; expiresAt: number };
};

/** One small Effect-owned pool per server instance for hang report ingest and retention. */
async function hangReportsDatabaseRuntime(): Promise<Runtime> {
  const config = cloudDbConfig();
  const key = `${cloudDbConfigKey(config)}:hang-reports:${POOL_MAX}`;
  const current = globals.__cmuxHangReportsEffectDatabase;
  if (current?.key === key && current.expiresAt > Date.now()) return current.runtime;
  const connection = config.driver === "url"
    ? { url: Redacted.make(config.url) }
    : {
      host: config.host,
      port: config.port,
      database: config.database,
      username: config.user,
      ssl: { rejectUnauthorized: config.sslRejectUnauthorized, ...(config.sslCaPem ? { ca: config.sslCaPem } : {}) },
      password: Redacted.make(await new Signer({
        hostname: config.host,
        port: config.port,
        username: config.user,
        region: config.awsRegion,
        credentials: awsCredentialsProvider({ roleArn: config.awsRoleArn, clientConfig: { region: config.awsRegion } }),
      }).getAuthToken()),
    };
  const runtime = makeDatabaseRuntime({ ...connection, maxConnections: POOL_MAX, applicationName: "cmux-hang-reports" });
  // RDS IAM passwords are short-lived; PlanetScale URL credentials are not.
  globals.__cmuxHangReportsEffectDatabase = {
    key,
    runtime,
    expiresAt: config.driver === "url" ? Number.POSITIVE_INFINITY : Date.now() + 10 * 60_000,
  };
  if (current) void current.runtime.dispose();
  return runtime;
}

/**
 * Run a hang report program against Postgres. Connection and pool failures
 * become ``HangReportStorageUnavailable``; domain failures pass through.
 */
export async function runWithHangReportsDatabase<A, E>(
  program: Effect.Effect<A, E, HangReportsRepository>,
): Promise<Exit.Exit<A, E | HangReportStorageUnavailable>> {
  let runtime: Runtime;
  try {
    runtime = await hangReportsDatabaseRuntime();
  } catch (cause) {
    return Exit.fail(new HangReportStorageUnavailable({ operation: "connect", cause }));
  }
  const exit = await runtime.runPromiseExit(program.pipe(Effect.provide(HangReportsRepositoryLive)));
  return Exit.mapError(exit, (error) =>
    isHangReportError(error) ? error as E | HangReportStorageUnavailable : new HangReportStorageUnavailable({ operation: "connect", cause: error }));
}
