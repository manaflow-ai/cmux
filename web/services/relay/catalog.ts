import {
  createHash,
  createPrivateKey,
  randomUUID,
  sign as edSign,
  type KeyObject,
} from "node:crypto";

import {
  RelayConfigurationError,
  RelaySigningError,
} from "./errors";
import {
  RELAY_POLICY_AUDIENCE,
  RELAY_POLICY_PROTOCOL,
  RELAY_POLICY_TYP,
  RELAY_POLICY_VERSION,
  parseRelayCatalog,
  type RelayCatalog,
  type RelayPolicyPayload,
} from "./model";
import {
  MANAGED_IROH_RELAY_CATALOG,
} from "./generated/managedRelayCatalog";

export const RELAY_POLICY_TTL_SECONDS = 300;
export const RELAY_ROTATION_MIN_OVERLAP_SECONDS = RELAY_POLICY_TTL_SECONDS;

export type RelayPolicySigningKey = {
  readonly kid: string;
  readonly key: KeyObject;
};

export function configuredRelayCatalog(): RelayCatalog {
  return parseRelayCatalog(JSON.stringify(MANAGED_IROH_RELAY_CATALOG));
}

export function relayCatalogDigest(catalog: RelayCatalog): string {
  const canonicalCatalog = {
    version: catalog.version,
    sequence: catalog.sequence,
    relays: catalog.relays.map((relay) => ({
      id: relay.id,
      provider: relay.provider,
      region: relay.region,
      url: relay.url,
    })),
  };
  return createHash("sha256").update(JSON.stringify(canonicalCatalog)).digest("hex");
}

/**
 * Enforces one safe add-before-remove fleet transition.
 *
 * Additions must retain every current relay. Removals must introduce no new
 * relay and must wait until every prior signed policy has expired. A stable ID
 * cannot change meaning in place; add a new ID first, then retire the old ID.
 */
export function assertSafeRelayCatalogRotation(input: {
  readonly current: RelayCatalog;
  readonly next: RelayCatalog;
  readonly overlapSeconds?: number;
}): void {
  const { current, next } = input;
  if (next.sequence <= current.sequence) {
    throw new RelayConfigurationError({ code: "catalog_invalid" });
  }
  const currentByID = new Map(current.relays.map((relay) => [relay.id, relay]));
  const nextByID = new Map(next.relays.map((relay) => [relay.id, relay]));
  for (const [id, relay] of currentByID) {
    const retained = nextByID.get(id);
    if (retained && JSON.stringify(retained) !== JSON.stringify(relay)) {
      throw new RelayConfigurationError({ code: "catalog_invalid" });
    }
  }
  const added = next.relays.filter((relay) => !currentByID.has(relay.id));
  const removed = current.relays.filter((relay) => !nextByID.has(relay.id));
  if (added.length > 0 && removed.length > 0) {
    throw new RelayConfigurationError({ code: "catalog_invalid" });
  }
  if (
    removed.length > 0 &&
    (input.overlapSeconds ?? 0) < RELAY_ROTATION_MIN_OVERLAP_SECONDS
  ) {
    throw new RelayConfigurationError({ code: "catalog_invalid" });
  }
}

let cachedSigningKey: {
  readonly kid: string;
  readonly pem: string;
  readonly value: RelayPolicySigningKey;
} | null = null;

export function relayPolicySigningKey(
  env: Readonly<Record<string, string | undefined>> = process.env,
): RelayPolicySigningKey {
  const kid = env.CMUX_RELAY_POLICY_KEY_ID?.trim();
  const pem = env.CMUX_RELAY_POLICY_PRIVATE_KEY_PEM
    ?.replace(/\\n/g, "\n")
    .trim();
  if (!kid || !pem) {
    throw new RelayConfigurationError({ code: "signing_key_not_configured" });
  }
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$/.test(kid)) {
    throw new RelayConfigurationError({ code: "signing_key_invalid" });
  }
  if (cachedSigningKey?.kid === kid && cachedSigningKey.pem === pem) {
    return cachedSigningKey.value;
  }
  try {
    const key = createPrivateKey(pem);
    if (key.asymmetricKeyType !== "ed25519") {
      throw new Error("relay policy key must be Ed25519");
    }
    const value = { kid, key };
    cachedSigningKey = { kid, pem, value };
    return value;
  } catch {
    throw new RelayConfigurationError({ code: "signing_key_invalid" });
  }
}

function b64url(value: Buffer | string): string {
  return Buffer.from(value).toString("base64url");
}

export function relayPolicyPayload(input: {
  readonly catalog: RelayCatalog;
  readonly nowSeconds: number;
  readonly jti?: string;
}): RelayPolicyPayload {
  const jti = (input.jti ?? randomUUID()).toLowerCase();
  if (UUID_RE.test(jti) === false) {
    throw new RelaySigningError({ cause: new Error("invalid policy jti") });
  }
  return {
    version: RELAY_POLICY_VERSION,
    jti,
    sequence: input.catalog.sequence,
    iat: input.nowSeconds,
    // Backdate the activation edge slightly so normal request latency and
    // small client/server clock differences do not strand a fresh policy.
    nbf: input.nowSeconds - 5,
    exp: input.nowSeconds + RELAY_POLICY_TTL_SECONDS,
    aud: RELAY_POLICY_AUDIENCE,
    relay_protocol: RELAY_POLICY_PROTOCOL,
    relays: input.catalog.relays,
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export function signRelayPolicy(input: {
  readonly payload: RelayPolicyPayload;
  readonly signingKey: RelayPolicySigningKey;
}): string {
  const header = {
    alg: "EdDSA",
    typ: RELAY_POLICY_TYP,
    kid: input.signingKey.kid,
  } as const;
  try {
    const signingInput = `${b64url(JSON.stringify(header))}.${b64url(
      JSON.stringify(input.payload),
    )}`;
    const signature = edSign(
      null,
      Buffer.from(signingInput),
      input.signingKey.key,
    );
    return `${signingInput}.${b64url(signature)}`;
  } catch (cause) {
    throw new RelaySigningError({ cause });
  }
}
