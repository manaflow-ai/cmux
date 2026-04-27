export type CloudDbUrlConfig = {
  readonly driver: "url";
  readonly url: string;
  readonly poolMax: number;
};

export type CloudDbAwsRdsIamConfig = {
  readonly driver: "aws-rds-iam";
  readonly awsRegion: string;
  readonly awsRoleArn: string;
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly database: string;
  readonly poolMax: number;
  readonly sslRejectUnauthorized: boolean;
};

export type CloudDbConfig = CloudDbUrlConfig | CloudDbAwsRdsIamConfig;

type Env = Record<string, string | undefined>;

const awsEnvKeys = ["AWS_REGION", "AWS_ROLE_ARN", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE"] as const;

function envValue(env: Env, key: string): string | undefined {
  const value = env[key]?.trim();
  return value ? value : undefined;
}

function parsePositiveInteger(value: string | undefined, key: string, fallback: number): number {
  if (!value) return fallback;
  if (!/^\d+$/.test(value)) {
    throw new Error(`${key} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${key} must be a positive integer`);
  }
  return parsed;
}

function parseBoolean(value: string | undefined, fallback: boolean): boolean {
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  throw new Error("boolean env value must be one of true/false/1/0/yes/no/on/off");
}

function missingAwsKeys(env: Env): readonly string[] {
  return awsEnvKeys.filter((key) => !envValue(env, key));
}

function shouldUseAwsRdsIam(env: Env): boolean {
  const requestedDriver = envValue(env, "CMUX_DB_DRIVER");
  if (requestedDriver) {
    if (requestedDriver === "aws-rds-iam") return true;
    if (requestedDriver === "url" || requestedDriver === "postgres-url") return false;
    throw new Error("CMUX_DB_DRIVER must be url, postgres-url, or aws-rds-iam");
  }

  const hasUrl = Boolean(envValue(env, "DIRECT_DATABASE_URL") ?? envValue(env, "DATABASE_URL"));
  return !hasUrl && missingAwsKeys(env).length === 0;
}

export function cloudDbConfig(env: Env = process.env): CloudDbConfig {
  const poolMax = parsePositiveInteger(envValue(env, "CMUX_DB_POOL_MAX"), "CMUX_DB_POOL_MAX", 5);

  if (shouldUseAwsRdsIam(env)) {
    const missing = missingAwsKeys(env);
    if (missing.length > 0) {
      throw new Error(`aws-rds-iam database config is missing: ${missing.join(", ")}`);
    }

    return {
      driver: "aws-rds-iam",
      awsRegion: envValue(env, "AWS_REGION")!,
      awsRoleArn: envValue(env, "AWS_ROLE_ARN")!,
      host: envValue(env, "PGHOST")!,
      port: parsePositiveInteger(envValue(env, "PGPORT"), "PGPORT", 5432),
      user: envValue(env, "PGUSER")!,
      database: envValue(env, "PGDATABASE")!,
      poolMax,
      sslRejectUnauthorized: parseBoolean(envValue(env, "CMUX_DB_SSL_REJECT_UNAUTHORIZED"), false),
    };
  }

  const url = envValue(env, "DIRECT_DATABASE_URL") ?? envValue(env, "DATABASE_URL");
  if (!url) {
    throw new Error("DATABASE_URL is required for Cloud VM database access");
  }
  return { driver: "url", url, poolMax };
}

export function cloudDbConfigKey(config: CloudDbConfig): string {
  if (config.driver === "url") return `url:${config.url}`;
  return [
    "aws-rds-iam",
    config.awsRegion,
    config.awsRoleArn,
    config.host,
    config.port,
    config.user,
    config.database,
    config.poolMax,
    config.sslRejectUnauthorized,
  ].join(":");
}
