import { createPrivateKey, randomUUID, sign } from "node:crypto";

const CLOUD_GRANT_SCOPE = "cmux.cloud.attach";
const CLOUD_GRANT_TYPE = "cmux-cloud-vm-grant+jwt";
const CLOUD_GRANT_TTL_SECONDS = 300;

function encodeJson(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

/**
 * Sign the capability used by a private cmux-tui daemon. The daemon carries
 * only the public verification key. The claim binds the grant to the VM and
 * the caller's Noise device fingerprint, so VPC reachability is never the
 * authorization boundary.
 *
 * The signing key intentionally uses the existing server-side Ed25519 key
 * configuration. The token type and scope are distinct from mobile Iroh
 * grants, and the key never enters a guest image.
 */
export function signCloudVmGrant(input: {
  readonly vmId: string;
  readonly deviceFingerprint: string;
  readonly nowSeconds?: number;
}): { token: string; expiresAtUnix: number } {
  if (!input.vmId || !input.deviceFingerprint) {
    throw new Error("cloud VM grant requires a VM id and device fingerprint");
  }
  const privateKeyPem = process.env.CMUX_IROH_GRANT_SIGNING_KEY_P8?.replaceAll("\\n", "\n").trim();
  const kid = process.env.CMUX_IROH_GRANT_SIGNING_KID?.trim();
  if (!privateKeyPem || !kid) {
    throw new Error("cloud VM grant signing is not configured");
  }
  const privateKey = createPrivateKey(privateKeyPem);
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("cloud VM grant signing key must be Ed25519");
  }
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  const claims = {
    jti: randomUUID(),
    iat: now,
    nbf: now,
    exp: now + CLOUD_GRANT_TTL_SECONDS,
    scope: CLOUD_GRANT_SCOPE,
    vm_id: input.vmId,
    device_fingerprint: input.deviceFingerprint,
  };
  const header = encodeJson({ alg: "EdDSA", typ: CLOUD_GRANT_TYPE, kid });
  const payload = encodeJson(claims);
  const signingInput = `${header}.${payload}`;
  const signature = sign(null, Buffer.from(signingInput, "ascii"), privateKey).toString("base64url");
  return { token: `${signingInput}.${signature}`, expiresAtUnix: claims.exp };
}
