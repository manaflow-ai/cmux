export interface EncryptedPushTuple extends Record<string, unknown> {
  readonly accountID: string;
  readonly teamID?: string | null;
  readonly iosBuildID: string;
  readonly iosInstallationID: string;
  readonly macDeviceID: string;
  readonly macInstanceTag?: string | null;
  readonly macBuildID: string;
}

export interface EncryptedPushPayload extends Record<string, unknown> {
  readonly version: 2;
  readonly installationID: string;
  readonly keyID: string;
  readonly senderKeyID: string;
  readonly encapsulatedKey: string;
  readonly ciphertext: string;
  readonly tuple: EncryptedPushTuple;
}

const envelopeFields = new Set([
  "version", "installationID", "keyID", "senderKeyID",
  "encapsulatedKey", "ciphertext", "tuple",
]);
const tupleFields = new Set([
  "accountID", "teamID", "iosBuildID", "iosInstallationID",
  "macDeviceID", "macInstanceTag", "macBuildID",
]);

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 255
    && value.trim() === value
    && Array.from(value).every((character) => {
      const code = character.charCodeAt(0);
      return code >= 32 && code !== 127;
    });
}

function optionalIdentifier(value: unknown): boolean {
  return value === undefined || value === null || identifier(value);
}

function base64(value: unknown, minimum: number, maximum: number): boolean {
  if (typeof value !== "string" || value.length > Math.ceil(maximum / 3) * 4
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return false;
  }
  const bytes = Buffer.from(value, "base64");
  return bytes.length >= minimum && bytes.length <= maximum
    && bytes.toString("base64") === value;
}

function isTuple(value: unknown): value is EncryptedPushTuple {
  return object(value)
    && Object.keys(value).every((key) => tupleFields.has(key))
    && identifier(value.accountID)
    && optionalIdentifier(value.teamID)
    && identifier(value.iosBuildID)
    && identifier(value.iosInstallationID)
    && identifier(value.macDeviceID)
    && optionalIdentifier(value.macInstanceTag)
    && identifier(value.macBuildID);
}

/** Notification envelopes target the iOS installation named in the tuple. */
export function isEncryptedPushPayload(value: unknown): value is EncryptedPushPayload {
  return object(value)
    && Object.keys(value).every((key) => envelopeFields.has(key))
    && value.version === 2
    && identifier(value.installationID)
    && identifier(value.keyID)
    && identifier(value.senderKeyID)
    && base64(value.encapsulatedKey, 32, 32)
    && base64(value.ciphertext, 16, 8192)
    && isTuple(value.tuple)
    && value.installationID === value.tuple.iosInstallationID;
}
