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

/** The live layer from the Worker secret. A secret that does not parse is logged (never its content) and disables service keys. */
export const serviceKeysLayer = (raw: string | undefined): Layer.Layer<ServiceKeys> => {
  const parsed = parseServiceKeys(raw);
  if (!parsed.ok) console.error("cmux-vm CMUX_VM_SERVICE_KEYS is invalid; service keys are disabled");
  return Layer.succeed(ServiceKeys, makeServiceKeys(parsed.keys));
};
