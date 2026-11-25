/**
 * CI trust: a GitHub Actions job authenticates with the OIDC token GitHub
 * mints for it, not with a stored key. Nothing long-lived exists to copy,
 * rotate or leak; revoking a job is removing its row.
 *
 * The rows come from the plain Worker var CMUX_VM_CI_TRUST (they hold no
 * secret), a JSON array:
 *
 *   [{ "id": "ci-product-smoke", "audience": "https://vm.cmux.dev",
 *      "repository": "manaflow-ai/cmux", "environment": "cmux-vm-production",
 *      "workflowRef": "manaflow-ai/cmux/.github/workflows/cmux-vm.yml@refs/heads/feat-cmux-next",
 *      "team": "cmux-vm-product-smoke", "scopes": ["vm:read", "vm:write", "vm:exec"],
 *      "labels": { "cmux.ci": "product-smoke" }, "maxVms": 2, "maxUsdPerHour": 1, "maxRunSeconds": 900 }]
 *
 * A token matches a row only when GitHub signed it (RS256, GitHub's own JWKS,
 * never a key the token names), it is unexpired and at most 15 minutes old,
 * and its audience, repository, environment and workflow_ref (the workflow
 * file and the ref it ran from; job_workflow_ref too when GitHub sends one)
 * all equal the row's. The row maps it
 * to a service principal of its own id: one team, the row's scopes (VM read,
 * write and exec only), confined to VMs carrying the row's labels, at most
 * `maxVms` live VMs within `maxUsdPerHour`, and every VM it creates pauses
 * after `maxRunSeconds` and is deleted once stopped. It is not any platform
 * service: an image, entitlement or quota grant names this id explicitly.
 */
import { Context, Data, Effect, Layer, Option, Schema } from "effect";
import { decodeJwt, errors as joseErrors, jwtVerify, type JWTVerifyGetKey } from "jose";
import { Scope } from "../domain/scopes.ts";
import { TenantId } from "../lib/ids.ts";
import { cachedJwks, isTokenRejection, looksLikeCompactJws } from "./credentials.ts";

export const GITHUB_ACTIONS_ISSUER = "https://token.actions.githubusercontent.com";
const GITHUB_ACTIONS_JWKS = new URL(`${GITHUB_ACTIONS_ISSUER}/.well-known/jwks`);
/** GitHub's job tokens live about five minutes; anything older is refused even if unexpired. */
const MAX_TOKEN_AGE = "15m";

/** The only scopes a CI row may hold: a smoke creates, reads, execs in and deletes its own VMs. */
export const CI_TRUST_SCOPES = ["vm:read", "vm:write", "vm:exec"] as const satisfies ReadonlyArray<Scope>;

const LABEL_KEY = /^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?$/u;
const LABEL_VALUE = /^[A-Za-z0-9._:/@-]{1,63}$/u;
const NonEmpty = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256));

const CiTrustEntry = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^ci-[a-z0-9-]{1,37}$/u)),
  audience: Schema.String.pipe(Schema.pattern(/^https:\/\/[a-z0-9.-]+$/u)),
  repository: Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u)),
  environment: NonEmpty,
  /** workflow_ref (and job_workflow_ref when present): `<owner>/<repo>/<workflow path>@<ref>`. */
  workflowRef: Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/\.github\/workflows\/[A-Za-z0-9_./-]+\.ya?ml@refs\/[A-Za-z0-9_./-]+$/u)),
  team: TenantId,
  scopes: Schema.Array(Schema.Literal(...CI_TRUST_SCOPES)).pipe(Schema.minItems(1)),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }).pipe(
    Schema.filter(
      (labels) => {
        const entries = Object.entries(labels);
        return entries.length >= 1 && entries.every(([key, value]) => LABEL_KEY.test(key) && LABEL_VALUE.test(value));
      },
      { message: () => "a CI trust row needs at least one label it is limited to" },
    ),
  ),
  maxVms: Schema.Int.pipe(Schema.between(1, 5)),
  maxUsdPerHour: Schema.Number.pipe(Schema.greaterThan(0), Schema.lessThanOrEqualTo(5)),
  maxRunSeconds: Schema.Int.pipe(Schema.between(60, 3600)),
});

const CiTrustList = Schema.Array(CiTrustEntry).pipe(
  Schema.filter((rows) => new Set(rows.map((row) => row.id)).size === rows.length, { message: () => "CI trust ids must be unique" }),
);

export interface CiTrustRow {
  readonly id: string;
  readonly audience: string;
  readonly repository: string;
  readonly environment: string;
  readonly workflowRef: string;
  readonly team: TenantId;
  readonly scopes: ReadonlySet<Scope>;
  readonly labels: Readonly<Record<string, string>>;
  readonly maxVms: number;
  readonly maxUsdPerHour: number;
  readonly maxRunSeconds: number;
}

/** Parses CMUX_VM_CI_TRUST. Absent or blank: no rows. Invalid: none, and `ok` is false. */
export const parseCiTrust = (raw: string | undefined): { readonly ok: boolean; readonly rows: ReadonlyArray<CiTrustRow> } => {
  if (raw === undefined || raw.trim().length === 0) return { ok: true, rows: [] };
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, rows: [] };
  }
  const decoded = Schema.decodeUnknownOption(CiTrustList)(json);
  if (Option.isNone(decoded)) return { ok: false, rows: [] };
  return { ok: true, rows: decoded.value.map((row) => ({ ...row, scopes: new Set(row.scopes), labels: { ...row.labels } })) };
};

/** The token claims to be GitHub's but does not match a trust row (or is not validly signed). */
export class CiTokenRejected extends Data.TaggedError("CiTokenRejected")<{ readonly reason: string }> {}
/** GitHub's JWKS could not be fetched; says nothing about the caller. */
export class CiTrustUnavailable extends Data.TaggedError("CiTrustUnavailable")<{ readonly reason: string }> {}

export interface CiTrustMatch {
  readonly row: CiTrustRow;
  readonly expiresAt: Date;
}

export interface CiTrustService {
  /**
   * None: the token is not a GitHub Actions token (it may be a session). Some: GitHub signed it and it matches the row.
   * A GitHub token that matches no row, or fails verification, fails with CiTokenRejected.
   */
  readonly verify: (raw: string, now: Date) => Effect.Effect<Option.Option<CiTrustMatch>, CiTokenRejected | CiTrustUnavailable>;
}

export class CiTrust extends Context.Tag("cmux-vm/CiTrust")<CiTrust, CiTrustService>() {}

/** Whether a compact JWS claims GitHub Actions as its issuer. Unverified: it only routes the token. */
const claimsGitHubIssuer = (raw: string): boolean => {
  if (!looksLikeCompactJws(raw)) return false;
  try {
    return decodeJwt(raw).iss === GITHUB_ACTIONS_ISSUER;
  } catch {
    return false;
  }
};

export const makeCiTrust = (
  rows: ReadonlyArray<CiTrustRow>,
  options: { readonly getKey?: JWTVerifyGetKey; readonly fetch?: (request: Request) => Promise<Response> } = {},
): CiTrustService => {
  const getKey = options.getKey ?? cachedJwks(GITHUB_ACTIONS_JWKS, options.fetch ?? ((request) => fetch(request)));
  const audiences = [...new Set(rows.map((row) => row.audience))];
  return {
    verify: (raw, now) =>
      Effect.gen(function* () {
        if (!claimsGitHubIssuer(raw)) return Option.none();
        if (rows.length === 0) return yield* Effect.fail(new CiTokenRejected({ reason: "no-trust" }));
        const { payload } = yield* Effect.tryPromise({
          try: () =>
            jwtVerify(raw, getKey, {
              algorithms: ["RS256"],
              issuer: GITHUB_ACTIONS_ISSUER,
              audience: audiences,
              clockTolerance: 60,
              maxTokenAge: MAX_TOKEN_AGE,
              currentDate: now,
              requiredClaims: ["exp", "iat", "repository", "environment", "workflow_ref"],
            }),
          catch: (error) =>
            isTokenRejection(error) || error instanceof joseErrors.JWTClaimValidationFailed
              ? new CiTokenRejected({ reason: "invalid" })
              : new CiTrustUnavailable({ reason: "jwks" }),
        });
        const tokenAudiences = typeof payload.aud === "string" ? [payload.aud] : (payload.aud ?? []);
        const row = rows.find(
          (candidate) =>
            tokenAudiences.includes(candidate.audience) &&
            payload["repository"] === candidate.repository &&
            payload["environment"] === candidate.environment &&
            payload["workflow_ref"] === candidate.workflowRef &&
            // A job from a reusable workflow names that file here; the row's file must define the job itself too.
            (payload["job_workflow_ref"] === undefined || payload["job_workflow_ref"] === candidate.workflowRef),
        );
        if (row === undefined || payload.exp === undefined) return yield* Effect.fail(new CiTokenRejected({ reason: "no-match" }));
        return Option.some({ row, expiresAt: new Date(payload.exp * 1000) });
      }),
  };
};

/** The live layer from the Worker var. A var that does not parse is logged (never its content) and trusts no job. */
export const ciTrustLayer = (raw: string | undefined): Layer.Layer<CiTrust> => {
  const parsed = parseCiTrust(raw);
  if (!parsed.ok) console.error("cmux-vm CMUX_VM_CI_TRUST is invalid; no CI job is trusted");
  return Layer.succeed(CiTrust, makeCiTrust(parsed.rows));
};
