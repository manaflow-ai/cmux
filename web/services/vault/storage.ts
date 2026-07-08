import {
  S3Client,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { vaultConfig } from "./config";
import { logVaultStorageError } from "./logging";

type HeadObjectResult = {
  readonly contentLength: number | null;
};

let cachedClientKey: string | null = null;
let cachedClient: S3Client | null = null;

function keyPart(value: string): string {
  // Stack user ids and agent/session ids are expected to be stable identifier
  // strings without path separators. This replacement is defense-in-depth for
  // object-key shape only; routes still derive keys server-side and never accept
  // client-provided key parts.
  return value.replace(/[^A-Za-z0-9._:-]/g, "_");
}

export function buildObjectKey(userId: string, agent: string, agentSessionId: string, sha256: string): string {
  return [
    "vault",
    "u",
    keyPart(userId),
    keyPart(agent),
    keyPart(agentSessionId),
    `${sha256}.jsonl.zst`,
  ].join("/");
}

function s3Client(): S3Client {
  const config = vaultConfig();
  const key = JSON.stringify({
    region: config.region,
    endpoint: config.endpoint ?? null,
    accessKeyId: config.accessKeyId ?? null,
  });
  if (cachedClient && cachedClientKey === key) return cachedClient;
  cachedClientKey = key;
  cachedClient = new S3Client({
    region: config.region,
    ...(config.endpoint ? { endpoint: config.endpoint, forcePathStyle: true } : {}),
    ...(config.accessKeyId && config.secretAccessKey
      ? {
          credentials: {
            accessKeyId: config.accessKeyId,
            secretAccessKey: config.secretAccessKey,
          },
        }
      : {}),
  });
  return cachedClient;
}

export async function presignPut(key: string, contentLength: number): Promise<string> {
  const config = vaultConfig();
  if (!config.bucket) throw new Error("CMUX_VAULT_S3_BUCKET is required");
  try {
    return await getSignedUrl(
      s3Client(),
      new PutObjectCommand({
        Bucket: config.bucket,
        Key: key,
        ContentType: "application/zstd",
        ContentLength: contentLength,
      }),
      { expiresIn: config.presignTtlSeconds },
    );
  } catch (error) {
    logVaultStorageError("presign_put", key, error);
    throw error;
  }
}

export async function presignGet(key: string): Promise<string> {
  const config = vaultConfig();
  if (!config.bucket) throw new Error("CMUX_VAULT_S3_BUCKET is required");
  try {
    return await getSignedUrl(
      s3Client(),
      new GetObjectCommand({
        Bucket: config.bucket,
        Key: key,
      }),
      { expiresIn: config.presignTtlSeconds },
    );
  } catch (error) {
    logVaultStorageError("presign_get", key, error);
    throw error;
  }
}

export async function deleteObject(key: string): Promise<void> {
  const config = vaultConfig();
  if (!config.bucket) throw new Error("CMUX_VAULT_S3_BUCKET is required");
  try {
    await s3Client().send(new DeleteObjectCommand({ Bucket: config.bucket, Key: key }));
  } catch (error) {
    logVaultStorageError("delete_object", key, error);
    throw error;
  }
}

export async function headObject(key: string): Promise<HeadObjectResult | null> {
  const config = vaultConfig();
  if (!config.bucket) throw new Error("CMUX_VAULT_S3_BUCKET is required");
  try {
    const result = await s3Client().send(new HeadObjectCommand({ Bucket: config.bucket, Key: key }));
    return { contentLength: typeof result.ContentLength === "number" ? result.ContentLength : null };
  } catch (error) {
    const status = (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
    const name = (error as { name?: string }).name;
    if (status === 404 || name === "NotFound" || name === "NoSuchKey") return null;
    logVaultStorageError("head_object", key, error);
    throw error;
  }
}
