import * as Redacted from "effect/Redacted";
import { cloudDbConfig, cloudDbConfigKey } from "../../db/config";
import { makeDatabaseRuntime } from "../../db/effect";

const globals = globalThis as typeof globalThis & {
  __cmuxPublicationEffectDatabase?: { key: string; runtime: ReturnType<typeof makeDatabaseRuntime> };
};

/** One Effect-owned database pool per server instance, separate from background traffic. */
export function publicationDatabaseRuntime() {
  const config = cloudDbConfig();
  if (config.driver !== "url") throw new Error("Publication Effect database requires a PostgreSQL connection URL");
  const configuredMax = process.env.CMUX_PUBLICATION_AUTH_DB_POOL_MAX?.trim() ?? "5";
  if (!/^\d+$/u.test(configuredMax) || Number(configuredMax) < 1 || Number(configuredMax) > 32) {
    throw new Error("CMUX_PUBLICATION_AUTH_DB_POOL_MAX must be between 1 and 32");
  }
  const key = `${cloudDbConfigKey(config)}:publication-auth:${configuredMax}`;
  const current = globals.__cmuxPublicationEffectDatabase;
  if (current?.key === key) return current.runtime;
  const runtime = makeDatabaseRuntime({
    url: Redacted.make(config.url),
    maxConnections: Number(configuredMax),
    applicationName: "cmux-publication-auth",
  });
  globals.__cmuxPublicationEffectDatabase = { key, runtime };
  if (current) void current.runtime.dispose();
  return runtime;
}

export async function closePublicationAuthDb(): Promise<void> {
  const current = globals.__cmuxPublicationEffectDatabase;
  globals.__cmuxPublicationEffectDatabase = undefined;
  await current?.runtime.dispose();
}
