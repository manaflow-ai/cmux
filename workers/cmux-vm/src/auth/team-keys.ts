/**
 * Team keys: long-lived `cmuxvm_sk_` keys a team's own agents and services use headless (a lane VM running
 * `cmux vm new`, a demand scaler), with no person signed in and no confirm per call. Each one acts for exactly one
 * team, holds VM scopes only, reaches only VMs carrying its labels, and is held to a machine count (`maxVms`) and an
 * estimated USD/h budget (`maxUsdPerHour`) on every create; a create over either cap is refused with 429 naming the
 * cap. A row may also set `maxRunningVms` (VMs running at once), `maxUsdPerDay` and `maxUsdPerMonth` (estimated spend
 * in the UTC day and month), checked on every create and every start or resume, each refusal naming the cap and its
 * current value; absent, each is no limit. Unlike an agent key (src/domain/agents.ts) it does not expire, and nothing deletes its VMs: machines persist,
 * pause when idle and are resumed; rotating the key keeps them, since they carry the row's labels, not the key's.
 *
 * The rows come from the plain Worker var CMUX_VM_TEAM_KEYS (hashes only, no secret), a JSON array:
 *
 *   [{ "id": "tk-lanes", "team": "<Stack team id>", "sha256": ["<64 hex>"],
 *      "scopes": ["vm:read", "vm:write", "vm:exec"], "labels": { "cmux.team-key": "lanes" },
 *      "maxVms": 20, "maxUsdPerHour": 10 }]
 *
 * `sha256` takes one or two hashes, so a rotation adds the new key, moves its holders, then drops the old one.
 * Minting is `bun scripts/team-key.ts mint` (the key to a 0600 file, the row to stdout); revoking is removing the
 * row (or its hash) and deploying. A team key authenticates like a service key acting for its one team: the
 * X-Cmux-Team-Id header may be left out, and naming another team is 403. Its creates are entitled as the team's own
 * (MANAFLOW_TEAM_TENANT_IDS) or by listing the row id in CMUX_VM_ENTITLED_SERVICE_IDS.
 */
import { Option, Schema } from "effect";
import { CI_TRUST_SCOPES } from "./ci-trust.ts";
import { TenantId } from "../lib/ids.ts";
import type { ServiceKey } from "./service-keys.ts";

/** The most a team key may hold: a machine count and a $/h budget well past one team's fleet, short of unbounded. */
export const TEAM_KEY_LIMITS = { maxVms: 500, maxUsdPerHour: 500, maxUsdPerDay: 500 * 24, maxUsdPerMonth: 500 * 24 * 31 } as const;

const LABEL_KEY = /^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?$/u;
const LABEL_VALUE = /^[A-Za-z0-9._:/@-]{1,63}$/u;
const Sha256 = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/u));

const TeamKeyEntry = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^tk-[a-z0-9-]{1,37}$/u)),
  team: TenantId,
  sha256: Schema.Array(Sha256).pipe(Schema.minItems(1), Schema.maxItems(2)),
  scopes: Schema.Array(Schema.Literal(...CI_TRUST_SCOPES)).pipe(Schema.minItems(1)),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }).pipe(
    Schema.filter(
      (labels) => {
        const entries = Object.entries(labels);
        return entries.length >= 1 && entries.every(([key, value]) => LABEL_KEY.test(key) && LABEL_VALUE.test(value));
      },
      { message: () => "a team key needs at least one label it is limited to" },
    ),
  ),
  maxVms: Schema.Int.pipe(Schema.between(1, TEAM_KEY_LIMITS.maxVms)),
  maxUsdPerHour: Schema.Number.pipe(Schema.greaterThan(0), Schema.lessThanOrEqualTo(TEAM_KEY_LIMITS.maxUsdPerHour)),
  // Optional caps (RFD 0016 "Keys and caps"); absent: no limit.
  maxRunningVms: Schema.optional(Schema.Int.pipe(Schema.between(1, TEAM_KEY_LIMITS.maxVms))),
  maxUsdPerDay: Schema.optional(Schema.Number.pipe(Schema.greaterThan(0), Schema.lessThanOrEqualTo(TEAM_KEY_LIMITS.maxUsdPerDay))),
  maxUsdPerMonth: Schema.optional(Schema.Number.pipe(Schema.greaterThan(0), Schema.lessThanOrEqualTo(TEAM_KEY_LIMITS.maxUsdPerMonth))),
});

const TeamKeyList = Schema.Array(TeamKeyEntry).pipe(
  Schema.filter(
    (rows) => {
      const hashes = rows.flatMap((row) => row.sha256);
      return new Set(rows.map((row) => row.id)).size === rows.length && new Set(hashes).size === hashes.length;
    },
    { message: () => "team key ids and hashes must be unique" },
  ),
);

/**
 * Parses CMUX_VM_TEAM_KEYS into service keys, one per hash, each limited to its row's team and carrying its budget.
 * Absent or blank: none. Invalid: none, and `ok` is false.
 */
export const parseTeamKeys = (raw: string | undefined): { readonly ok: boolean; readonly keys: ReadonlyArray<ServiceKey> } => {
  if (raw === undefined || raw.trim().length === 0) return { ok: true, keys: [] };
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, keys: [] };
  }
  const decoded = Schema.decodeUnknownOption(TeamKeyList)(json);
  if (Option.isNone(decoded)) return { ok: false, keys: [] };
  return {
    ok: true,
    keys: decoded.value.flatMap((row) =>
      row.sha256.map(
        (sha256): ServiceKey => ({
          id: row.id,
          sha256,
          scopes: new Set(row.scopes),
          labels: { ...row.labels },
          teams: new Set([row.team]),
          budget: {
            maxVms: row.maxVms,
            maxUsdPerHour: row.maxUsdPerHour,
            holder: `team key ${row.id}`,
            ...(row.maxRunningVms === undefined ? {} : { maxRunningVms: row.maxRunningVms }),
            ...(row.maxUsdPerDay === undefined ? {} : { maxUsdPerDay: row.maxUsdPerDay }),
            ...(row.maxUsdPerMonth === undefined ? {} : { maxUsdPerMonth: row.maxUsdPerMonth }),
          },
        }),
      ),
    ),
  };
};
