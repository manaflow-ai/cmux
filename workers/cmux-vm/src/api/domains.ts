/**
 * Domains, TLS rules and forward-auth checks (cx-b4h.6): the provider's
 * `domain` and `tls` surface, tenant-scoped. Every resource here belongs to one
 * tenant through cmux's own tables (migration 0018); another tenant's id is
 * 404 and absent from lists. A tenant routes only managed hostnames under the
 * deployment's zone and custom domains it verified itself; TLS rules name only
 * its own VMs; secret header values are write-only. Account-wide provider
 * settings (placeholder branding) are not exposed.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { VmId } from "../lib/ids.ts";
import { DomainId, DomainVerificationId, ForwardAuthId, TlsRuleId } from "../lib/domain-ids.ts";
import { describe, GroupTeamHeaders } from "./common.ts";

const CONFINED = "Service keys, agent keys and resource-allowlisted keys cannot create these resources; allowlisted keys see only the ids they list.";

export const DnsRecord = Schema.Struct({
  name: Schema.String,
  type: Schema.Literal("TXT", "CNAME", "NS"),
  value: Schema.String,
}).annotations({ identifier: "DnsRecord", description: "One DNS record to publish at your DNS host." });

export class DomainDns extends Schema.Class<DomainDns>("DomainDns")({
  routing: Schema.NullOr(DnsRecord).annotations({
    description: "Point names under the domain at the edge (a CNAME for subdomains; the apex needs ALIAS/ANAME or CNAME flattening to the same value). Null when the deployment publishes no edge host.",
  }),
  wildcardCertificate: Schema.NullOr(DnsRecord).annotations({
    description: "Delegate `_acme-challenge.<domain>` before requesting a wildcard certificate. Null when the deployment publishes no certificate nameserver.",
  }),
}) {}

export class Domain extends Schema.Class<Domain>("Domain")({
  id: DomainId,
  domain: Schema.String,
  verifiedAt: Schema.String,
  dns: DomainDns,
}, { description: "A custom domain your team proved it controls. TLS rules may route it and one label below it." }) {}

export class DomainList extends Schema.Class<DomainList>("DomainList")({
  items: Schema.Array(Domain),
  managedSuffix: Schema.NullOr(Schema.String).annotations({
    description: "Managed hostnames of your team are one label ending in this suffix (for example `app` + suffix); they need no verification. Null when the deployment has no managed zone.",
  }),
}) {}

export class DomainVerification extends Schema.Class<DomainVerification>("DomainVerification")({
  id: DomainVerificationId,
  domain: Schema.String,
  state: Schema.Literal("pending", "verified"),
  record: DnsRecord.annotations({ description: "Publish this TXT record, then call verify." }),
  createdAt: Schema.String,
  verifiedAt: Schema.NullOr(Schema.String),
}, { description: "One ownership challenge. Only the team that created it can see it or complete it." }) {}

export class DomainVerificationList extends Schema.Class<DomainVerificationList>("DomainVerificationList")({
  items: Schema.Array(DomainVerification),
}) {}

export class CreateDomainVerificationRequest extends Schema.Class<CreateDomainVerificationRequest>("CreateDomainVerificationRequest")({
  domain: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(253)),
}) {}

export const ListDomainVerificationsParams = Schema.Struct({
  state: Schema.optional(Schema.Literal("pending", "verified")),
});

export class Certificate extends Schema.Class<Certificate>("Certificate")({
  domain: Schema.String,
  wildcard: Schema.Boolean,
  active: Schema.Boolean,
  notAfter: Schema.String,
  generation: Schema.Number,
}) {}

export class CertificateList extends Schema.Class<CertificateList>("CertificateList")({
  items: Schema.Array(Certificate),
}) {}

/** Header values are write-only: accepted here, never returned or logged. */
export const SecretHeaders = Schema.Redacted(Schema.Record({ key: Schema.String, value: Schema.String })).annotations({
  identifier: "SecretHeaders",
  description: "Header names to values. Write-only: values are never returned; responses list only the names.",
  jsonSchema: { type: "object", additionalProperties: { type: "string" }, maxProperties: 16, writeOnly: true },
});

export const TlsProtocol = Schema.Literal("http", "tcp", "postgres", "minecraft", "imap", "imaps").annotations({
  identifier: "TlsProtocol",
  description: "http (443, terminated), tcp (443, SNI splice to your VM's own certificate), postgres (5432, terminated), minecraft (25565), imap (993 terminated) or imaps (993 spliced). Egress rules are http only.",
});

const Port = Schema.Int.pipe(Schema.between(1, 65_535));

export const HttpRequestMatch = Schema.Struct({
  method: Schema.optional(Schema.Array(Schema.String.pipe(Schema.pattern(/^[A-Z]{1,16}$/u))).pipe(Schema.maxItems(16))),
  path: Schema.optional(Schema.Struct({ exact: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(2048), Schema.pattern(/^\//u)) })),
}).annotations({
  identifier: "HttpRequestMatch",
  description: "Egress only: which requests get the header transform (methods ORed, path exact). Others pass through unchanged.",
  parseOptions: { onExcessProperty: "error" },
});

export const TlsRuleRequest = Schema.Struct({
  domain: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(255)).annotations({
    description: "The name the session is addressed to: one hostname, or `*.` plus a verified domain you own (ingress only).",
  }),
  protocol: Schema.optional(TlsProtocol).annotations({ description: "Defaults to http." }),
  source: Schema.Struct({
    vmId: Schema.optional(Schema.String.pipe(Schema.maxLength(64))),
    public: Schema.optional(Schema.Literal(true)),
  }).annotations({ parseOptions: { onExcessProperty: "error" }, description: "Exactly one: `public: true` (ingress from the Internet) or one of your VMs (egress)." }),
  destination: Schema.Struct({
    vmId: Schema.optional(Schema.String.pipe(Schema.maxLength(64))),
    port: Schema.optional(Port),
    host: Schema.optional(Schema.String.pipe(Schema.maxLength(253))),
    public: Schema.optional(Schema.Literal(true)),
  }).annotations({
    parseOptions: { onExcessProperty: "error" },
    description: "Ingress: one of your VMs plus a port. Egress: `public: true` or `host` + `port`, which must be an HTTPS origin the deployment approved.",
  }),
  forwardAuthId: Schema.optional(Schema.NullOr(Schema.String.pipe(Schema.maxLength(64)))).annotations({
    description: "Ingress http only: run this forward-auth check of yours before each request reaches the VM.",
  }),
  match: Schema.optional(Schema.NullOr(HttpRequestMatch)),
  headers: Schema.optional(SecretHeaders).annotations({ description: "http only: headers set on each request. Write-only." }),
  description: Schema.optional(Schema.NullOr(Schema.String.pipe(Schema.maxLength(1024)))),
}).annotations({
  identifier: "TlsRuleRequest",
  parseOptions: { onExcessProperty: "error" },
  // A rejected header must not echo its value in the decode error.
  message: () => ({ message: "Invalid TLS rule", override: true }),
});
export type TlsRuleRequest = typeof TlsRuleRequest.Type;

/** What a rule says, without secrets: stored by cmux and returned as is. */
export const TlsRuleSpec = Schema.Struct({
  domain: Schema.String,
  protocol: TlsProtocol,
  direction: Schema.Literal("ingress", "egress"),
  source: Schema.Struct({ vmId: Schema.optional(VmId), public: Schema.optional(Schema.Literal(true)) }),
  destination: Schema.Struct({
    vmId: Schema.optional(VmId),
    port: Schema.optional(Schema.Int),
    host: Schema.optional(Schema.String),
    public: Schema.optional(Schema.Literal(true)),
  }),
  forwardAuthId: Schema.NullOr(ForwardAuthId),
  match: Schema.NullOr(HttpRequestMatch),
  headerNames: Schema.Array(Schema.String).annotations({ description: "Names of the headers the rule sets; values are never returned." }),
  description: Schema.NullOr(Schema.String),
});
export type TlsRuleSpec = typeof TlsRuleSpec.Type;

export class TlsRule extends Schema.Class<TlsRule>("TlsRule")({
  id: TlsRuleId,
  ...TlsRuleSpec.fields,
  createdAt: Schema.String,
  updatedAt: Schema.String,
}, { description: "A named session over a hostname to or from your own VMs. Deleting a VM it names deletes the rule." }) {}

export class TlsRuleList extends Schema.Class<TlsRuleList>("TlsRuleList")({ items: Schema.Array(TlsRule) }) {}

export const ListTlsRulesParams = Schema.Struct({ vmId: Schema.optional(Schema.String.pipe(Schema.maxLength(64))) });

export const TlsForwardAuthRequest = Schema.Struct({
  url: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(2048)).annotations({ description: "Absolute HTTPS URL that receives a bodyless GET before each protected request." }),
  headers: Schema.optional(SecretHeaders),
  authResponseHeaders: Schema.optional(Schema.Array(Schema.String.pipe(Schema.maxLength(128))).pipe(Schema.maxItems(16))).annotations({
    description: "Headers copied from a successful check onto the request to the VM.",
  }),
  protectedCookies: Schema.optional(Schema.Array(Schema.String.pipe(Schema.maxLength(128))).pipe(Schema.maxItems(16))).annotations({
    description: "Cookie names the check sees but the VM never receives.",
  }),
  timeoutMs: Schema.optional(Schema.Int.pipe(Schema.between(100, 5000))).annotations({ description: "Per-check deadline; defaults to 1500." }),
}).annotations({
  identifier: "TlsForwardAuthRequest",
  parseOptions: { onExcessProperty: "error" },
  message: () => ({ message: "Invalid forward-auth configuration", override: true }),
});
export type TlsForwardAuthRequest = typeof TlsForwardAuthRequest.Type;

export class TlsForwardAuth extends Schema.Class<TlsForwardAuth>("TlsForwardAuth")({
  id: ForwardAuthId,
  url: Schema.String,
  headerNames: Schema.Array(Schema.String),
  authResponseHeaders: Schema.Array(Schema.String),
  protectedCookies: Schema.Array(Schema.String),
  timeoutMs: Schema.Int,
  createdAt: Schema.String,
  updatedAt: Schema.String,
}, { description: "A reusable authorization check for public HTTP ingress. Header values are write-only." }) {}

export class TlsForwardAuthList extends Schema.Class<TlsForwardAuthList>("TlsForwardAuthList")({ items: Schema.Array(TlsForwardAuth) }) {}

const DomainPath = Schema.Struct({ domainId: Schema.String });
const VerificationPath = Schema.Struct({ verificationId: Schema.String });
const RulePath = Schema.Struct({ ruleId: Schema.String });
const ForwardAuthPath = Schema.Struct({ forwardAuthId: Schema.String });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class DomainsGroupDefinition extends HttpApiGroup.make("domains")
  .add(HttpApiEndpoint.get("listDomains", "/v1/domains")
    .setHeaders(GroupTeamHeaders).addSuccess(DomainList).addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List your verified domains", "domain:read", `Also names your managed hostname suffix. ${CONFINED}`)))
  .add(HttpApiEndpoint.get("getDomain", "/v1/domains/:domainId")
    .setHeaders(GroupTeamHeaders).setPath(DomainPath).addSuccess(Domain).addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Read a verified domain", "domain:read")))
  .add(HttpApiEndpoint.del("deleteDomain", "/v1/domains/:domainId")
    .setHeaders(GroupTeamHeaders).setPath(DomainPath).addSuccess(HttpApiSchema.NoContent)
    .addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Release a verified domain", "domain:write", "Refused (409) while a TLS rule of yours routes a name under it. Another team may then verify it with its own challenge.")))
  .add(HttpApiEndpoint.post("requestWildcardCertificate", "/v1/domains/:domainId/wildcard-certificate")
    .setHeaders(GroupTeamHeaders).setPath(DomainPath).addSuccess(Certificate)
    .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Request an ongoing wildcard certificate for a verified domain", "domain:write", "Delegate `_acme-challenge.<domain>` first (see the domain's dns.wildcardCertificate); wildcards can only be proven over DNS.")))
  .add(HttpApiEndpoint.get("listCertificates", "/v1/certificates")
    .setHeaders(GroupTeamHeaders).addSuccess(CertificateList).addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List certificates for your verified domains", "domain:read", "Only certificates for names under domains your team verified (the most specific verified domain decides).")))
  .add(HttpApiEndpoint.post("createDomainVerification", "/v1/domain-verifications")
    .setHeaders(GroupTeamHeaders).setPayload(CreateDomainVerificationRequest).addSuccess(DomainVerification, { status: 201 })
    .addError(BadRequest).addError(Forbidden).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Start proving you control a domain", "domain:write", `Reserves the domain for your team while the challenge is pending (another team's request is 409). An unverified reservation lapses 7 days after your team's first request: another request, or withdrawing every challenge and starting again, does not extend it. After it lapses any other team may reserve it at once, while your team gets 409 for another 7 days. Names under the managed zone cannot be verified. ${CONFINED}`)))
  .add(HttpApiEndpoint.get("listDomainVerifications", "/v1/domain-verifications")
    .setHeaders(GroupTeamHeaders).setUrlParams(ListDomainVerificationsParams).addSuccess(DomainVerificationList)
    .addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List your domain verifications", "domain:read")))
  .add(HttpApiEndpoint.get("getDomainVerification", "/v1/domain-verifications/:verificationId")
    .setHeaders(GroupTeamHeaders).setPath(VerificationPath).addSuccess(DomainVerification)
    .addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Read a domain verification", "domain:read")))
  .add(HttpApiEndpoint.post("verifyDomain", "/v1/domain-verifications/:verificationId/verify")
    .setHeaders(GroupTeamHeaders).setPath(VerificationPath).addSuccess(Domain)
    .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Check the TXT record and verify the domain", "domain:write", "Only this challenge's own code counts. 400 while the record is not visible yet; retrying after success returns the domain.")))
  .add(HttpApiEndpoint.del("deleteDomainVerification", "/v1/domain-verifications/:verificationId")
    .setHeaders(GroupTeamHeaders).setPath(VerificationPath).addSuccess(HttpApiSchema.NoContent)
    .addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Withdraw a pending domain verification", "domain:write", "A completed verification is a permanent record (409); release the domain instead. Withdrawing does not release or reset the reservation: it still lapses 7 days after your team's first request."))) {}

export class TlsRulesGroupDefinition extends HttpApiGroup.make("tlsRules")
  .add(HttpApiEndpoint.get("listTlsRules", "/v1/tls-rules")
    .setHeaders(GroupTeamHeaders).setUrlParams(ListTlsRulesParams).addSuccess(TlsRuleList).addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List your TLS rules, newest first", "domain:read", "Only rules whose VMs you can reach; filter by one VM with vmId.")))
  .add(HttpApiEndpoint.post("createTlsRule", "/v1/tls-rules")
    .setHeaders(GroupTeamHeaders).setPayload(TlsRuleRequest).addSuccess(TlsRule, { status: 201 })
    .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Create a TLS rule", "domain:write", `Also requires vm:network; every VM it names must be yours. Ingress (source public) routes a managed hostname or a verified domain of yours to one of your VMs; egress (source one of your VMs) reaches only HTTPS origins the deployment approved. Private networks, socks5 and credential transforms other than headers are not offered. ${CONFINED}`)))
  .add(HttpApiEndpoint.get("getTlsRule", "/v1/tls-rules/:ruleId")
    .setHeaders(GroupTeamHeaders).setPath(RulePath).addSuccess(TlsRule).addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Read a TLS rule", "domain:read", "Header values are never returned.")))
  .add(HttpApiEndpoint.put("updateTlsRule", "/v1/tls-rules/:ruleId")
    .setHeaders(GroupTeamHeaders).setPath(RulePath).setPayload(TlsRuleRequest).addSuccess(TlsRule)
    .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Replace a TLS rule in place", "domain:write", "The body is a whole rule, checked like a create (also requires vm:network). Rotates header secrets without dropping traffic; omitted headers clear them.")))
  .add(HttpApiEndpoint.del("deleteTlsRule", "/v1/tls-rules/:ruleId")
    .setHeaders(GroupTeamHeaders).setPath(RulePath).addSuccess(HttpApiSchema.NoContent)
    .addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Delete a TLS rule", "domain:write", "The VMs it named are untouched."))) {}

export class TlsForwardAuthGroupDefinition extends HttpApiGroup.make("tlsForwardAuth")
  .add(HttpApiEndpoint.get("listTlsForwardAuths", "/v1/tls-forward-auths")
    .setHeaders(GroupTeamHeaders).addSuccess(TlsForwardAuthList).addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List your forward-auth checks, newest first", "domain:read")))
  .add(HttpApiEndpoint.post("createTlsForwardAuth", "/v1/tls-forward-auths")
    .setHeaders(GroupTeamHeaders).setPayload(TlsForwardAuthRequest).addSuccess(TlsForwardAuth, { status: 201 })
    .addError(BadRequest).addError(Forbidden).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Create a forward-auth check", "domain:write", `The edge sends a bodyless GET to the URL before forwarding a protected request to your VM. Header values are write-only. ${CONFINED}`)))
  .add(HttpApiEndpoint.get("getTlsForwardAuth", "/v1/tls-forward-auths/:forwardAuthId")
    .setHeaders(GroupTeamHeaders).setPath(ForwardAuthPath).addSuccess(TlsForwardAuth).addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Read a forward-auth check", "domain:read", "Header values are never returned.")))
  .add(HttpApiEndpoint.put("updateTlsForwardAuth", "/v1/tls-forward-auths/:forwardAuthId")
    .setHeaders(GroupTeamHeaders).setPath(ForwardAuthPath).setPayload(TlsForwardAuthRequest).addSuccess(TlsForwardAuth)
    .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Replace a forward-auth check in place", "domain:write", "Rules keep referencing the same id; omitted headers clear them.")))
  .add(HttpApiEndpoint.del("deleteTlsForwardAuth", "/v1/tls-forward-auths/:forwardAuthId")
    .setHeaders(GroupTeamHeaders).setPath(ForwardAuthPath).addSuccess(HttpApiSchema.NoContent)
    .addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Delete an unused forward-auth check", "domain:write", "Refused (409) while a TLS rule uses it."))) {}
