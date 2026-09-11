import { z } from "zod";
import { DeviceDescriptorSchema, RelayCredentialSchema, identifier, relayURL, type DeviceDescriptor } from "./contracts/common";
import { RELAY_CREDENTIAL_SECONDS, canonicalJSON, encodeBase64URL, hash } from "./crypto";
import { OperationError } from "./errors";

const ConfigurationSchema = z.strictObject({
  environment: identifier, projectId: identifier, issuer: identifier, audience: identifier, keyId: identifier,
  privateKeyPem: z.string().min(1).max(4096), relayURLs: z.array(relayURL).min(1).max(16),
});
export type RelayConfiguration = z.infer<typeof ConfigurationSchema>;

/** The relay receives only the matching public key and verifies offline. */
export class RelayIssuer {
  readonly configuration: RelayConfiguration;
  private key: Promise<CryptoKey> | undefined;

  constructor(configuration: RelayConfiguration) { this.configuration = ConfigurationSchema.parse(configuration); }

  async issue(device: DeviceDescriptor, now: number, selectedURLs = this.configuration.relayURLs) {
    DeviceDescriptorSchema.parse(device);
    if (device.identity.environment !== this.configuration.environment || device.identity.projectId !== this.configuration.projectId) {
      throw new OperationError("environment_mismatch", 403);
    }
    if (selectedURLs.length === 0 || selectedURLs.some(url => !this.configuration.relayURLs.includes(url))) {
      throw new OperationError("invalid_request", 400);
    }
    const expiresAt = now + RELAY_CREDENTIAL_SECONDS;
    // Stable across this user's teams and devices; claims never contain a private route.
    const subject = await hash(canonicalJSON({
      environment: device.identity.environment, projectId: device.identity.projectId, userId: device.identity.userId,
    }));
    const header = encodeBase64URL(new TextEncoder().encode(canonicalJSON({ alg: "EdDSA", typ: "JWT", kid: this.configuration.keyId })));
    const body = encodeBase64URL(new TextEncoder().encode(canonicalJSON({
      iss: this.configuration.issuer, aud: this.configuration.audience, sub: subject,
      iat: now, exp: expiresAt, endpoint_id: device.endpointId,
      environment: device.identity.environment, project_id: device.identity.projectId,
      team_id: device.identity.teamId, identity_generation: device.identityGeneration,
    })));
    const signingInput = header + "." + body;
    let signed: ArrayBuffer;
    try { signed = await crypto.subtle.sign("Ed25519", await this.signingKey(), new TextEncoder().encode(signingInput)); }
    catch { throw new OperationError("upstream_unavailable", 503, true, 5000); }
    const token = signingInput + "." + encodeBase64URL(new Uint8Array(signed));
    return [...new Set(selectedURLs)].map(url => RelayCredentialSchema.parse({
      relayURL: url, token, expiresAt, refreshAfter: expiresAt - 300,
    }));
  }

  private signingKey(): Promise<CryptoKey> {
    this.key ??= (async () => {
      const match = /^-----BEGIN PRIVATE KEY-----\s*([A-Za-z0-9+/=\s]+)\s*-----END PRIVATE KEY-----\s*$/.exec(this.configuration.privateKeyPem);
      if (!match?.[1]) throw new Error("Invalid relay signing key");
      const bytes = Uint8Array.from(atob(match[1].replace(/\s/g, "")), char => char.charCodeAt(0));
      return crypto.subtle.importKey("pkcs8", bytes, { name: "Ed25519" }, false, ["sign"]);
    })();
    return this.key;
  }
}
