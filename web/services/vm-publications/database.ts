import * as Redacted from "effect/Redacted";
import { cloudDbConfig, cloudDbConfigKey } from "../../db/config";
import { makeDatabaseRuntime } from "../../db/effect";
import { Signer } from "@aws-sdk/rds-signer";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";

const globals = globalThis as typeof globalThis & {
  __cmuxPublicationEffectDatabase?: { key: string; runtime: ReturnType<typeof makeDatabaseRuntime>; expiresAt: number };
};

/** One Effect-owned database pool per server instance, separate from background traffic. */
export async function publicationDatabaseRuntime() {
  const config = cloudDbConfig();
  const configuredMax = process.env.CMUX_PUBLICATION_AUTH_DB_POOL_MAX?.trim() ?? "5";
  if (!/^\d+$/u.test(configuredMax) || Number(configuredMax) < 1 || Number(configuredMax) > 32) {
    throw new Error("CMUX_PUBLICATION_AUTH_DB_POOL_MAX must be between 1 and 32");
  }
  const key = `${cloudDbConfigKey(config)}:publication-auth:${configuredMax}`;
  const current = globals.__cmuxPublicationEffectDatabase;
  if (current?.key === key && current.expiresAt > Date.now()) return current.runtime;
  const connection = config.driver === "url"
    ? { url: Redacted.make(config.url) }
    : {
      host: config.host,
      port: config.port,
      database: config.database,
      username: config.user,
      ssl: { rejectUnauthorized: config.sslRejectUnauthorized, ...(config.sslCaPem ? { ca: config.sslCaPem } : {}) },
      password: Redacted.make(await new Signer({ hostname: config.host, port: config.port, username: config.user, region: config.awsRegion, credentials: awsCredentialsProvider({ roleArn: config.awsRoleArn, clientConfig: { region: config.awsRegion } }) }).getAuthToken()),
    };
  const runtime = makeDatabaseRuntime({
    ...connection,
    maxConnections: Number(configuredMax),
    applicationName: "cmux-publication-auth",
  });
  // PlanetScale passwords remain valid for the lifetime of the application.
  // RDS IAM passwords are short-lived, so refresh the Effect layer before the
  // token reaches its expiry instead of reusing a dead credential.
  globals.__cmuxPublicationEffectDatabase = { key, runtime, expiresAt: config.driver === "url" ? Number.POSITIVE_INFINITY : Date.now() + 10 * 60_000 };
  if (current) void current.runtime.dispose();
  return runtime;
}

export async function closePublicationAuthDb(): Promise<void> {
  const current = globals.__cmuxPublicationEffectDatabase;
  globals.__cmuxPublicationEffectDatabase = undefined;
  await current?.runtime.dispose();
}
