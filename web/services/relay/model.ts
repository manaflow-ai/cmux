import { z } from "zod";

import { RelayConfigurationError, RelayPreferenceValidationError } from "./errors";

export const RELAY_POLICY_VERSION = 1 as const;
export const RELAY_POLICY_AUDIENCE = "cmux-iroh-relay-policy" as const;
export const RELAY_POLICY_PROTOCOL = "iroh-relay-v1" as const;
export const RELAY_POLICY_TYP = "cmux-relay-policy-v1+jwt" as const;
// Matches `CmxIrohRelayPolicyVerifier.maximumRelayCount`. Keep the signed
// server catalog within the client's bounded decode and endpoint limits.
export const MAX_MANAGED_RELAYS = 16;
export const MAX_CUSTOM_RELAYS = 16;

const relayIDSchema = z.string().trim().min(1).max(64).regex(/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/);
const relayLabelSchema = z.string().trim().min(1).max(80).regex(/^[A-Za-z0-9](?:[A-Za-z0-9._ -]*[A-Za-z0-9])?$/);

function normalizedRelayURL(value: string): string {
  const parsed = new URL(value);
  if (
    parsed.protocol !== "https:" ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    (parsed.pathname !== "" && parsed.pathname !== "/")
  ) {
    throw new Error("relay URL must be a credential-free HTTPS origin");
  }
  parsed.pathname = "/";
  return parsed.toString();
}

const relayURLSchema = z.string().trim().min(1).max(2_048).transform((value, context) => {
  try {
    return normalizedRelayURL(value);
  } catch {
    context.addIssue({
      code: "custom",
      message: "relay URL must be a credential-free HTTPS origin",
    });
    return z.NEVER;
  }
});

export const managedRelaySchema = z.object({
  id: relayIDSchema,
  provider: relayLabelSchema,
  region: relayLabelSchema,
  url: relayURLSchema,
}).strict();

export type ManagedRelay = z.infer<typeof managedRelaySchema>;

const relayCatalogSchema = z.object({
  version: z.literal(RELAY_POLICY_VERSION),
  sequence: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  relays: z.array(managedRelaySchema).min(1).max(MAX_MANAGED_RELAYS),
}).strict();

export type RelayCatalog = z.infer<typeof relayCatalogSchema>;

export function parseRelayCatalog(raw: string | undefined): RelayCatalog {
  if (!raw?.trim()) {
    throw new RelayConfigurationError({ code: "catalog_not_configured" });
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new RelayConfigurationError({ code: "catalog_invalid" });
  }
  const parsed = relayCatalogSchema.safeParse(decoded);
  if (!parsed.success) {
    throw new RelayConfigurationError({ code: "catalog_invalid" });
  }
  const ids = new Set<string>();
  const urls = new Set<string>();
  for (const relay of parsed.data.relays) {
    if (ids.has(relay.id) || urls.has(relay.url)) {
      throw new RelayConfigurationError({ code: "catalog_invalid" });
    }
    ids.add(relay.id);
    urls.add(relay.url);
  }
  return parsed.data;
}

export const customRelaySchema = z.object({
  id: relayIDSchema,
  provider: relayLabelSchema,
  region: relayLabelSchema,
  url: relayURLSchema,
  displayName: z.string().trim().min(1).max(100).optional(),
  authMode: z.enum(["none", "device_secret"]),
}).strict();

export type CustomRelay = z.infer<typeof customRelaySchema>;

export const relayPreferenceSchema = z.object({
  mode: z.enum(["automatic", "managed", "custom"]),
  selectedManagedRelayIds: z.array(relayIDSchema).max(MAX_MANAGED_RELAYS),
  customRelays: z.array(customRelaySchema).max(MAX_CUSTOM_RELAYS),
}).strict().superRefine((preference, context) => {
  if (preference.mode === "managed" && preference.selectedManagedRelayIds.length === 0) {
    context.addIssue({
      code: "custom",
      path: ["selectedManagedRelayIds"],
      message: "managed mode requires at least one selected relay",
    });
  }
  if (preference.mode === "custom" && preference.customRelays.length === 0) {
    context.addIssue({
      code: "custom",
      path: ["customRelays"],
      message: "custom mode requires at least one saved relay",
    });
  }
});

export type RelayPreference = z.infer<typeof relayPreferenceSchema>;

export const defaultRelayPreference: RelayPreference = {
  mode: "automatic",
  selectedManagedRelayIds: [],
  customRelays: [],
};

const preferenceUpdateSchema = z.object({
  expectedRevision: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),
  preference: z.unknown(),
}).strict();

const forbiddenCredentialKey = /^(?:token|authtoken|authorization|password|secret|apikey|credential|bearer)$/i;

function containsCredentialField(value: unknown): boolean {
  const pending: unknown[] = [value];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current || typeof current !== "object") continue;
    if (Array.isArray(current)) {
      pending.push(...current);
      continue;
    }
    for (const [key, nested] of Object.entries(current as Record<string, unknown>)) {
      if (forbiddenCredentialKey.test(key.replace(/[_-]/g, ""))) return true;
      pending.push(nested);
    }
  }
  return false;
}

function hasUniqueRelayMetadata(relays: readonly { id: string; url: string }[]): boolean {
  return new Set(relays.map((relay) => relay.id)).size === relays.length &&
    new Set(relays.map((relay) => relay.url)).size === relays.length;
}

export function parseRelayPreferenceUpdate(raw: unknown): {
  readonly expectedRevision?: number;
  readonly preference: RelayPreference;
} {
  if (containsCredentialField(raw)) {
    throw new RelayPreferenceValidationError({ code: "credential_fields_forbidden" });
  }
  const envelope = preferenceUpdateSchema.safeParse(raw);
  if (!envelope.success) {
    throw new RelayPreferenceValidationError({ code: "invalid_preference" });
  }
  const preference = relayPreferenceSchema.safeParse(envelope.data.preference);
  if (!preference.success) {
    throw new RelayPreferenceValidationError({ code: "invalid_preference" });
  }
  if (
    new Set(preference.data.selectedManagedRelayIds).size !==
      preference.data.selectedManagedRelayIds.length
  ) {
    throw new RelayPreferenceValidationError({ code: "invalid_preference" });
  }
  if (!hasUniqueRelayMetadata(preference.data.customRelays)) {
    throw new RelayPreferenceValidationError({ code: "invalid_preference" });
  }
  const customIDs = new Set(preference.data.customRelays.map((relay) => relay.id));
  if (preference.data.selectedManagedRelayIds.some((id) => customIDs.has(id))) {
    throw new RelayPreferenceValidationError({ code: "invalid_preference" });
  }
  return {
    ...(envelope.data.expectedRevision === undefined
      ? {}
      : { expectedRevision: envelope.data.expectedRevision }),
    preference: preference.data,
  };
}

export function assertManagedSelectionExists(
  preference: RelayPreference,
  catalog: RelayCatalog,
): void {
  if (preference.mode !== "managed") return;
  const configured = new Set(catalog.relays.map((relay) => relay.id));
  const unknown = preference.selectedManagedRelayIds.filter((id) => !configured.has(id));
  if (unknown.length > 0) {
    throw new RelayPreferenceValidationError({
      code: "unknown_managed_relay",
      relayIds: unknown,
    });
  }
}

export type RelayPolicyPayload = {
  readonly version: 1;
  readonly jti: string;
  readonly sequence: number;
  readonly iat: number;
  readonly nbf: number;
  readonly exp: number;
  readonly aud: typeof RELAY_POLICY_AUDIENCE;
  readonly relay_protocol: typeof RELAY_POLICY_PROTOCOL;
  readonly relays: readonly ManagedRelay[];
};
