export type VaultStorageConfig = {
  readonly enabled: boolean;
  readonly bucket: string | null;
  readonly region: string;
  readonly endpoint?: string;
  readonly accessKeyId?: string;
  readonly secretAccessKey?: string;
  readonly presignTtlSeconds: number;
  readonly maxUploadBytes: number;
};

type Env = Record<string, string | undefined>;

const DEFAULT_PRESIGN_TTL_SECONDS = 900;
const DEFAULT_MAX_UPLOAD_BYTES = 512 * 1024 * 1024;

function envValue(env: Env, key: string): string | undefined {
  const value = env[key]?.trim();
  return value ? value : undefined;
}

function parseBoolean(value: string | undefined, fallback: boolean): boolean {
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  throw new Error("boolean env value must be one of true/false/1/0/yes/no/on/off");
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

export function vaultConfig(env: Env = process.env): VaultStorageConfig {
  const bucket = envValue(env, "CMUX_VAULT_S3_BUCKET") ?? null;
  const accessKeyId = envValue(env, "CMUX_VAULT_S3_ACCESS_KEY_ID");
  const secretAccessKey = envValue(env, "CMUX_VAULT_S3_SECRET_ACCESS_KEY");
  if ((accessKeyId && !secretAccessKey) || (!accessKeyId && secretAccessKey)) {
    throw new Error("CMUX_VAULT_S3_ACCESS_KEY_ID and CMUX_VAULT_S3_SECRET_ACCESS_KEY must be set together");
  }

  const enabled = parseBoolean(envValue(env, "CMUX_VAULT_ENABLED"), Boolean(bucket));
  return {
    enabled,
    bucket,
    region: envValue(env, "CMUX_VAULT_S3_REGION") ?? "auto",
    endpoint: envValue(env, "CMUX_VAULT_S3_ENDPOINT"),
    accessKeyId,
    secretAccessKey,
    presignTtlSeconds: parsePositiveInteger(
      envValue(env, "CMUX_VAULT_PRESIGN_TTL_SECONDS"),
      "CMUX_VAULT_PRESIGN_TTL_SECONDS",
      DEFAULT_PRESIGN_TTL_SECONDS,
    ),
    maxUploadBytes: parsePositiveInteger(
      envValue(env, "CMUX_VAULT_MAX_UPLOAD_BYTES"),
      "CMUX_VAULT_MAX_UPLOAD_BYTES",
      DEFAULT_MAX_UPLOAD_BYTES,
    ),
  };
}

export function isVaultConfigured(env: Env = process.env): boolean {
  const config = vaultConfig(env);
  return config.enabled && Boolean(config.bucket);
}
