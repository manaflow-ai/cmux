import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import {
  DecryptCommand,
  GenerateDataKeyCommand,
  KMSClient,
} from "@aws-sdk/client-kms";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";
import type {
  CodeRouterCredential,
  CodeRouterProvider,
} from "./types";

const ALGORITHM = "aes-256-gcm" as const;
const DATA_KEY_BYTES = 32;
const NONCE_BYTES = 12;
const AUTH_TAG_BYTES = 16;
const CREDENTIAL_REFRESH_SKEW_MS = 5 * 60 * 1_000;

export type EncryptedCredential = {
  readonly accountId: string;
  readonly teamId: string;
  readonly provider: CodeRouterProvider;
  readonly credentialRevision: number;
  readonly algorithm: typeof ALGORITHM;
  readonly ciphertext: string;
  readonly nonce: string;
  readonly authTag: string;
  readonly encryptedDataKey: string;
  readonly kmsKeyId: string;
};

export type CredentialKeyService = {
  generateDataKey(input: {
    readonly keyId: string;
    readonly encryptionContext: Readonly<Record<string, string>>;
  }): Promise<{ readonly plaintext: Uint8Array; readonly encrypted: Uint8Array }>;
  decryptDataKey(input: {
    readonly keyId: string;
    readonly encrypted: Uint8Array;
    readonly encryptionContext: Readonly<Record<string, string>>;
  }): Promise<Uint8Array>;
};

export async function encryptCredential(input: {
  readonly accountId: string;
  readonly teamId: string;
  readonly provider: CodeRouterProvider;
  readonly credentialRevision: number;
  readonly credential: CodeRouterCredential;
  readonly keyId?: string;
  readonly keys?: CredentialKeyService;
}): Promise<EncryptedCredential> {
  assertIdentity(input);
  if (input.credential.provider !== input.provider) {
    throw new Error("credential provider does not match its account");
  }
  const keyId = input.keyId ?? requiredEnv("CODEROUTER_KMS_KEY_ID");
  const keys = input.keys ?? kmsKeyService();
  const aad = credentialAad(input);
  const context = credentialEncryptionContext(input);
  const generated = await keys.generateDataKey({
    keyId,
    encryptionContext: context,
  });
  const plaintextKey = Buffer.from(generated.plaintext);
  if (plaintextKey.byteLength !== DATA_KEY_BYTES) {
    plaintextKey.fill(0);
    throw new Error("KMS returned an invalid coderouter data key");
  }

  const nonce = randomBytes(NONCE_BYTES);
  const plaintext = Buffer.from(JSON.stringify(input.credential), "utf8");
  try {
    const cipher = createCipheriv(ALGORITHM, plaintextKey, nonce, {
      authTagLength: AUTH_TAG_BYTES,
    });
    cipher.setAAD(aad);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const authTag = cipher.getAuthTag();
    return {
      accountId: input.accountId,
      teamId: input.teamId,
      provider: input.provider,
      credentialRevision: input.credentialRevision,
      algorithm: ALGORITHM,
      ciphertext: ciphertext.toString("base64"),
      nonce: nonce.toString("base64"),
      authTag: authTag.toString("base64"),
      encryptedDataKey: Buffer.from(generated.encrypted).toString("base64"),
      kmsKeyId: keyId,
    };
  } finally {
    plaintext.fill(0);
    plaintextKey.fill(0);
  }
}

export async function decryptCredential(
  encrypted: EncryptedCredential,
  keys: CredentialKeyService = kmsKeyService(),
): Promise<CodeRouterCredential> {
  assertIdentity(encrypted);
  if (encrypted.algorithm !== ALGORITHM) {
    throw new Error("unsupported coderouter credential encryption algorithm");
  }
  const nonce = strictBase64(encrypted.nonce, "nonce");
  const authTag = strictBase64(encrypted.authTag, "authentication tag");
  const ciphertext = strictBase64(encrypted.ciphertext, "ciphertext");
  const wrappedKey = strictBase64(encrypted.encryptedDataKey, "encrypted data key");
  if (nonce.byteLength !== NONCE_BYTES || authTag.byteLength !== AUTH_TAG_BYTES) {
    throw new Error("invalid coderouter credential envelope");
  }
  const plaintextKey = Buffer.from(await keys.decryptDataKey({
    keyId: encrypted.kmsKeyId,
    encrypted: wrappedKey,
    encryptionContext: credentialEncryptionContext(encrypted),
  }));
  if (plaintextKey.byteLength !== DATA_KEY_BYTES) {
    plaintextKey.fill(0);
    throw new Error("KMS returned an invalid coderouter data key");
  }

  let plaintext: Buffer | undefined;
  try {
    const decipher = createDecipheriv(ALGORITHM, plaintextKey, nonce, {
      authTagLength: AUTH_TAG_BYTES,
    });
    decipher.setAAD(credentialAad(encrypted));
    decipher.setAuthTag(authTag);
    plaintext = Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ]);
    const value: unknown = JSON.parse(plaintext.toString("utf8"));
    const credential = parseCredential(value);
    if (!credential || credential.provider !== encrypted.provider) {
      throw new Error("decrypted coderouter credential is invalid");
    }
    return credential;
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error("decrypted coderouter credential is invalid");
    }
    throw error;
  } finally {
    plaintext?.fill(0);
    plaintextKey.fill(0);
  }
}

function credentialAad(input: {
  readonly accountId: string;
  readonly teamId: string;
  readonly provider: CodeRouterProvider;
  readonly credentialRevision: number;
}): Buffer {
  return Buffer.from(JSON.stringify([
    "coderouter",
    1,
    input.teamId,
    input.accountId,
    input.provider,
    input.credentialRevision,
  ]), "utf8");
}

function credentialEncryptionContext(input: {
  readonly accountId: string;
  readonly teamId: string;
  readonly provider: CodeRouterProvider;
  readonly credentialRevision: number;
}): Readonly<Record<string, string>> {
  return {
    service: "coderouter",
    version: "1",
    team: input.teamId,
    account: input.accountId,
    provider: input.provider,
    revision: String(input.credentialRevision),
  };
}

function assertIdentity(input: {
  readonly accountId: string;
  readonly teamId: string;
  readonly provider: CodeRouterProvider;
  readonly credentialRevision: number;
}): void {
  if (
    !input.accountId ||
    !input.teamId ||
    !["codex", "opencode-go"].includes(input.provider) ||
    !Number.isSafeInteger(input.credentialRevision) ||
    input.credentialRevision < 1
  ) {
    throw new Error("invalid coderouter credential identity");
  }
}

function strictBase64(value: string, label: string): Buffer {
  if (
    !value ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    throw new Error(`invalid coderouter credential ${label}`);
  }
  const decoded = Buffer.from(value, "base64");
  const canonical = decoded.toString("base64");
  if (
    canonical.length !== value.length ||
    !timingSafeEqual(Buffer.from(canonical), Buffer.from(value))
  ) {
    throw new Error(`invalid coderouter credential ${label}`);
  }
  return decoded;
}

function parseCredential(value: unknown): CodeRouterCredential | null {
  if (!isRecord(value)) return null;
  const {
    accessToken,
    refreshToken,
    accountId,
    email,
    expiresAt,
  } = value;
  if (
    !string(accessToken) ||
    !string(refreshToken) ||
    !string(accountId) ||
    !string(email) ||
    !positiveNumber(expiresAt)
  ) {
    return null;
  }
  if (value.provider === "codex" && string(value.idToken)) {
    return {
      provider: "codex",
      accessToken,
      refreshToken,
      idToken: value.idToken,
      accountId,
      email,
      expiresAt,
    };
  }
  if (value.provider === "opencode-go") {
    if (
      value.orgId !== undefined && typeof value.orgId !== "string" ||
      value.orgName !== undefined && typeof value.orgName !== "string"
    ) {
      return null;
    }
    return {
      provider: "opencode-go",
      accessToken,
      refreshToken,
      accountId,
      email,
      expiresAt,
      ...(value.orgId ? { orgId: value.orgId } : {}),
      ...(value.orgName ? { orgName: value.orgName } : {}),
    };
  }
  return null;
}

function string(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function positiveNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

let defaultKeyService: CredentialKeyService | undefined;

type AwsCredentials = {
  readonly accessKeyId: string;
  readonly secretAccessKey: string;
  readonly sessionToken?: string;
  readonly expiration?: Date;
};

export function coalescingCredentialsProvider(
  provider: () => Promise<AwsCredentials>,
  now: () => number = Date.now,
): () => Promise<AwsCredentials> {
  let current: AwsCredentials | undefined;
  let pending: Promise<AwsCredentials> | undefined;
  return async () => {
    if (
      current &&
      (!current.expiration ||
        current.expiration.getTime() > now() + CREDENTIAL_REFRESH_SKEW_MS)
    ) {
      return current;
    }
    if (pending) return await pending;
    pending = provider().then((credentials) => {
      current = credentials;
      return credentials;
    });
    try {
      return await pending;
    } finally {
      pending = undefined;
    }
  };
}

function kmsKeyService(): CredentialKeyService {
  if (defaultKeyService) return defaultKeyService;
  const region = requiredEnv("AWS_REGION");
  const runningOnVercel = Boolean(process.env.VERCEL);
  const roleArn = runningOnVercel
    ? requiredEnv("CODEROUTER_KMS_ROLE_ARN")
    : undefined;
  const client = new KMSClient({
    region,
    ...(runningOnVercel && roleArn
      ? {
        credentials: coalescingCredentialsProvider(
          awsCredentialsProvider({
            roleArn,
            clientConfig: { region },
          }),
        ),
      }
      : {}),
  });
  defaultKeyService = {
    async generateDataKey(input) {
      const output = await client.send(new GenerateDataKeyCommand({
        KeyId: input.keyId,
        KeySpec: "AES_256",
        EncryptionContext: { ...input.encryptionContext },
      }));
      if (!output.Plaintext || !output.CiphertextBlob) {
        throw new Error("KMS did not return a coderouter data key");
      }
      return {
        plaintext: output.Plaintext,
        encrypted: output.CiphertextBlob,
      };
    },
    async decryptDataKey(input) {
      const output = await client.send(new DecryptCommand({
        KeyId: input.keyId,
        CiphertextBlob: input.encrypted,
        EncryptionContext: { ...input.encryptionContext },
      }));
      if (!output.Plaintext) {
        throw new Error("KMS did not decrypt the coderouter data key");
      }
      return output.Plaintext;
    },
  };
  return defaultKeyService;
}

function requiredEnv(key: string): string {
  const value = process.env[key]?.trim();
  if (!value) throw new Error(`${key} is required`);
  return value;
}
