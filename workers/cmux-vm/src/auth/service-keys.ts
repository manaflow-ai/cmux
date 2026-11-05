/**
 * Service keys (cx-b4h.13): `cmuxvm_sk_` keys that belong to a cmux service,
 * not to a tenant. The first is Cloud Chief's. They come from the Worker
 * secret CMUX_VM_SERVICE_KEYS, a JSON array that holds only each key's
 * SHA-256 hash:
 *
 *   [{ "id": "cloud-chief", "sha256": "<64 hex>", "scopes": ["vm:read", "vm:write", "vm:exec"],
 *      "labels": { "role": "chief" }, "teams": null }]
 *
 * A service key acts for one team per request, named in X-Cmux-Team-Id, and
 * only on resources that carry every one of its `labels`; `teams` (optional)
 * limits which teams. A key with no labels would reach every VM of every team,
 * so the parser refuses it, as it refuses the `admin` scope. An invalid secret
 * disables every service key (and logs once); tenant keys and sessions keep
 * working.
 */
import { Context, Effect, Layer, Option, Schema } from "effect";
import { Scope } from "../domain/scopes.ts";
import { TenantId } from "../lib/ids.ts";

const LABEL_KEY = /^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?$/u;
const LABEL_VALUE = /^[A-Za-z0-9._:/@-]{1,63}$/u;

const ServiceKeyEntry = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^[a-z][a-z0-9-]{0,39}$/u)),
  sha256: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/u)),
  scopes: Schema.Array(Scope).pipe(
    Schema.minItems(1),
    Schema.filter((scopes) => !scopes.includes("admin"), { message: () => "a service key never holds the admin scope" }),
  ),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }).pipe(
    Schema.filter(
      (labels) => {
        const entries = Object.entries(labels);
        return entries.length >= 1 && entries.every(([key, value]) => LABEL_KEY.test(key) && LABEL_VALUE.test(value));
      },
      { message: () => "a service key needs at least one label it is limited to" },
    ),
  ),
  teams: Schema.optionalWith(Schema.NullOr(Schema.Array(TenantId).pipe(Schema.minItems(1))), { default: () => null }),
});

const ServiceKeyList = Schema.Array(ServiceKeyEntry).pipe(
  Schema.filter((keys) => new Set(keys.map((key) => key.id)).size === keys.length && new Set(keys.map((key) => key.sha256)).size === keys.length, {
    message: () => "service key ids and hashes must be unique",
  }),
);

export interface ServiceKey {
  readonly id: string;
  readonly sha256: string;
  readonly scopes: ReadonlySet<Scope>;
  /** Every resource the key reaches carries all of these labels; a VM it creates must too. */
  readonly labels: Readonly<Record<string, string>>;
  /** null: any team. */
  readonly teams: ReadonlySet<TenantId> | null;
}

export interface ServiceKeysService {
  /** The service key with this SHA-256 hash, if one is configured. */
  readonly find: (sha256: string) => Effect.Effect<Option.Option<ServiceKey>>;
}

export class ServiceKeys extends Context.Tag("cmux-vm/ServiceKeys")<ServiceKeys, ServiceKeysService>() {}

/** Parses the CMUX_VM_SERVICE_KEYS secret. Absent or blank: no service keys. Invalid: none, and `ok` is false. */
export const parseServiceKeys = (raw: string | undefined): { readonly ok: boolean; readonly keys: ReadonlyArray<ServiceKey> } => {
  if (raw === undefined || raw.trim().length === 0) return { ok: true, keys: [] };
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, keys: [] };
  }
  const decoded = Schema.decodeUnknownOption(ServiceKeyList)(json);
  if (Option.isNone(decoded)) return { ok: false, keys: [] };
  return {
    ok: true,
    keys: decoded.value.map((entry) => ({
      id: entry.id,
      sha256: entry.sha256,
      scopes: new Set(entry.scopes),
      labels: { ...entry.labels },
      teams: entry.teams === null ? null : new Set(entry.teams),
    })),
  };
};

export const makeServiceKeys = (keys: ReadonlyArray<ServiceKey>): ServiceKeysService => {
  const byHash = new Map(keys.map((key) => [key.sha256, key]));
  return { find: (sha256) => Effect.succeed(Option.fromNullable(byHash.get(sha256))) };
};

/**
 * Scopes a plain Worker var may add to a configured service key: the mesh ACL only. A key's entry lives in a
 * write-only secret, so a missing ACL scope could otherwise be added only by rotating the key. Never `admin`,
 * never a VM, file or exec scope: those stay in the secret entry.
 */
export const GRANTABLE_SERVICE_SCOPES = ["acl:read", "acl:write"] as const;

const SERVICE_KEY_ID = /^[a-z][a-z0-9-]{0,39}$/u;
const ServiceScopeGrants = Schema.Record({
  key: Schema.String,
  value: Schema.Array(Schema.Literal(...GRANTABLE_SERVICE_SCOPES)).pipe(Schema.minItems(1), Schema.maxItems(GRANTABLE_SERVICE_SCOPES.length)),
});

/**
 * Parses CMUX_VM_SERVICE_KEY_SCOPE_GRANTS, a JSON object of service key id to grantable scopes, e.g.
 * `{"cloud-platform-dev":["acl:read","acl:write"]}`. Absent or blank: none. Invalid: none, and `ok` is false.
 */
export const parseServiceScopeGrants = (
  raw: string | undefined,
): { readonly ok: boolean; readonly grants: ReadonlyMap<string, ReadonlyArray<Scope>> } => {
  if (raw === undefined || raw.trim().length === 0) return { ok: true, grants: new Map() };
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, grants: new Map() };
  }
  const decoded = Schema.decodeUnknownOption(ServiceScopeGrants)(json);
  // A malformed id fails the whole var instead of being dropped, so a typo is logged rather than silently granting less.
  if (Option.isNone(decoded) || !Object.keys(decoded.value).every((id) => SERVICE_KEY_ID.test(id))) return { ok: false, grants: new Map() };
  return { ok: true, grants: new Map(Object.entries(decoded.value)) };
};

/** Adds each key's granted scopes; a grant naming no configured key does nothing. Labels and teams are unchanged. */
export const applyServiceScopeGrants = (keys: ReadonlyArray<ServiceKey>, grants: ReadonlyMap<string, ReadonlyArray<Scope>>): ReadonlyArray<ServiceKey> =>
  keys.map((key) => {
    const extra = grants.get(key.id);
    return extra === undefined ? key : { ...key, scopes: new Set([...key.scopes, ...extra]) };
  });

/**
 * The live layer from the Worker secret. A secret that does not parse is logged (never its content) and disables
 * service keys. Invalid scope grants are logged and ignored: the keys keep exactly their secret entry's scopes.
 */
export const serviceKeysLayer = (raw: string | undefined, rawGrants?: string): Layer.Layer<ServiceKeys> => {
  const parsed = parseServiceKeys(raw);
  if (!parsed.ok) console.error("cmux-vm CMUX_VM_SERVICE_KEYS is invalid; service keys are disabled");
  const grants = parseServiceScopeGrants(rawGrants);
  if (!grants.ok) console.error("cmux-vm CMUX_VM_SERVICE_KEY_SCOPE_GRANTS is invalid; no scope is added");
  return Layer.succeed(ServiceKeys, makeServiceKeys(applyServiceScopeGrants(parsed.keys, grants.grants)));
};
