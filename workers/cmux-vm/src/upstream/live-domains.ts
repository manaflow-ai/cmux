/**
 * The live provider domain/TLS client (see src/upstream/domains.ts for the
 * interface). Imported only from src/upstream/, src/proofs/ and src/index.ts.
 * Provider ids of existing resources come only from minted proofs; rule and
 * forward-auth bodies only from proof evidence. Provider responses are decoded
 * to the few fields cmux needs; nothing else is passed on.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { domainUpstreamIdOf, type TenantOwnsDomainResource } from "../proofs/domain-resource.ts";
import { forwardAuthEvidenceOf, staleChallengeIdsOf, tlsRuleEvidenceOf, verifiableDomainOf } from "../proofs/tls-rule.ts";
import type { Environment } from "../policy.ts";
import { UpstreamError } from "./client.ts";
import { UpstreamCertificate, UpstreamDomains, type UpstreamDomainsService } from "./domains.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";

const Challenge = Schema.Struct({
  id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)),
  recordName: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(300)),
  verificationCode: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(512)),
});
const Verified = Schema.Struct({ verifiedBy: Schema.String });
const Created = Schema.Struct({ id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)) });
const Certificates = Schema.Struct({ certificates: Schema.Array(UpstreamCertificate) });

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

/** A provider id as a path segment; `.` and `..` would change the path, so they are refused. */
const segment = (operation: string, id: string): Effect.Effect<string, UpstreamError> =>
  id === "." || id === ".." ? Effect.fail(new UpstreamError({ operation, status: null })) : Effect.succeed(encodeURIComponent(id));

const idOf = <C, R>(operation: string, owns: TenantOwnsDomainResource<C, R>) =>
  Effect.flatMap(Effect.sync(() => domainUpstreamIdOf(owns)), (id) => segment(operation, id));

/** Maps the listed statuses to outcomes; any other failure stays an UpstreamError. */
const outcome = <A, const B, R>(effect: Effect.Effect<A, UpstreamError, R>, cases: Readonly<Record<number, B>>): Effect.Effect<A | B, UpstreamError, R> =>
  Effect.catchAll(effect, (error): Effect.Effect<B, UpstreamError> => {
    const mapped = error.status === null ? undefined : cases[error.status];
    return mapped === undefined ? Effect.fail(error) : Effect.succeed(mapped);
  });

export function makeUpstreamDomains(config: UpstreamConfig): UpstreamDomainsService {
  const http = makeUpstreamHttp(config);
  /** Best-effort cleanup of a resource just created; `.` and `..` are never sent as a path. */
  const discard = (operation: string, path: string, id: string): Effect.Effect<void> =>
    id === "." || id === ".." ? Effect.void : http.json(operation, "DELETE", path).pipe(Effect.ignore);
  return {
    createVerification: (domain) =>
      http.json("createVerification", "POST", "/v5/verifications", { domain: verifiableDomainOf(domain) }).pipe(
        Effect.flatMap(decodeAs(Challenge, "createVerification")),
        Effect.map((body) => ({
          upstreamId: UpstreamId.make(body.id), recordName: body.recordName, code: body.verificationCode,
          discard: discard("deleteVerification", `/v5/verifications/${encodeURIComponent(body.id)}`, body.id),
        })),
      ),
    verifyDomain: (owns, siblings) => Effect.gen(function* () {
      const operation = "verifyDomain";
      const id = yield* idOf(operation, owns);
      const upstreamId = domainUpstreamIdOf(owns);
      const result = yield* outcome(
        http.json(operation, "PUT", `/v5/verifications/${id}`).pipe(Effect.flatMap(decodeAs(Verified, operation)), Effect.map((body) => body.verifiedBy)),
        { 400: "pending", 404: "gone" },
      );
      if (result === "pending" || result === "gone") return result;
      // Only this challenge, or another challenge of the same tenant for the same domain, may have verified it.
      if (result !== upstreamId && !siblings.some((sibling) => sibling === result)) return yield* Effect.fail(new UpstreamError({ operation, status: null }));
      return "verified";
    }),
    withdrawStaleChallenges: (stale) =>
      Effect.forEach(staleChallengeIdsOf(stale), (id) => discard("deleteVerification", `/v5/verifications/${encodeURIComponent(id)}`, id), { discard: true }),
    deleteVerification: (owns) => Effect.gen(function* () {
      const id = yield* idOf("deleteVerification", owns);
      return yield* outcome(http.json("deleteVerification", "DELETE", `/v5/verifications/${id}`).pipe(Effect.as("deleted" as const)), { 404: "gone", 409: "verified" });
    }),
    listCertificates: http.json("listCertificates", "GET", "/v5/certificates").pipe(
      Effect.flatMap(decodeAs(Certificates, "listCertificates")),
      Effect.map((body) => body.certificates),
    ),
    requestWildcard: (domain) =>
      outcome(
        http.json("requestWildcard", "POST", "/v5/certificates/wildcard", { domain: verifiableDomainOf(domain) }).pipe(
          Effect.flatMap(decodeAs(UpstreamCertificate, "requestWildcard")),
        ),
        { 400: "refused", 403: "refused" },
      ),
    createTlsRule: (rule) =>
      http.json("createTlsRule", "POST", "/v5/tls", tlsRuleEvidenceOf(rule).body).pipe(
        Effect.flatMap(decodeAs(Created, "createTlsRule")),
        Effect.map((body) => ({ upstreamId: UpstreamId.make(body.id), discard: discard("deleteTlsRule", `/v5/tls/${encodeURIComponent(body.id)}`, body.id) })),
      ),
    getTlsRule: (owns) => Effect.gen(function* () {
      const id = yield* idOf("getTlsRule", owns);
      return yield* outcome(http.json("getTlsRule", "GET", `/v5/tls/${id}`).pipe(Effect.as("present" as const)), { 404: "gone" });
    }),
    updateTlsRule: (owns, rule) => Effect.gen(function* () {
      const id = yield* idOf("updateTlsRule", owns);
      return yield* outcome(http.json("updateTlsRule", "PUT", `/v5/tls/${id}`, tlsRuleEvidenceOf(rule).body).pipe(Effect.as("updated" as const)), { 404: "gone" });
    }),
    deleteTlsRule: (owns) => Effect.gen(function* () {
      const id = yield* idOf("deleteTlsRule", owns);
      return yield* outcome(http.json("deleteTlsRule", "DELETE", `/v5/tls/${id}`).pipe(Effect.as("deleted" as const)), { 404: "gone" });
    }),
    createForwardAuth: (auth) =>
      http.json("createForwardAuth", "POST", "/v5/tls/forward-auth", forwardAuthEvidenceOf(auth).body).pipe(
        Effect.flatMap(decodeAs(Created, "createForwardAuth")),
        Effect.map((body) => ({ upstreamId: UpstreamId.make(body.id), discard: discard("deleteForwardAuth", `/v5/tls/forward-auth/${encodeURIComponent(body.id)}`, body.id) })),
      ),
    updateForwardAuth: (owns, auth) => Effect.gen(function* () {
      const id = yield* idOf("updateForwardAuth", owns);
      return yield* outcome(http.json("updateForwardAuth", "PUT", `/v5/tls/forward-auth/${id}`, forwardAuthEvidenceOf(auth).body).pipe(Effect.as("updated" as const)), { 404: "gone" });
    }),
    deleteForwardAuth: (owns) => Effect.gen(function* () {
      const id = yield* idOf("deleteForwardAuth", owns);
      return yield* outcome(http.json("deleteForwardAuth", "DELETE", `/v5/tls/forward-auth/${id}`).pipe(Effect.as("deleted" as const)), { 404: "gone", 409: "in_use" });
    }),
  };
}

export const upstreamDomainsLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: Environment }): Layer.Layer<UpstreamDomains> =>
  Layer.succeed(UpstreamDomains, makeUpstreamDomains({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey), environment: config.environment }));
