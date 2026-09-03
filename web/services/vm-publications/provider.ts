import {
  FreestyleApiError,
  type CertificateInfo,
  type CreateTlsForwardAuthOptions,
  type CreateTlsRuleOptions,
  type DomainVerification,
  type DomainVerified,
  type ListTlsForwardAuthResult,
  type ListTlsRulesOptions,
  type ListTlsRulesResult,
  type TlsForwardAuthData,
  type TlsRuleData,
} from "freestyle";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { freestyleClient } from "../vms/drivers/freestyle";
import {
  PUBLICATION_SESSION_COOKIE,
  PUBLICATION_TRANSACTION_COOKIE,
  normalizePublicationHostname,
} from "./security";

export const CMUX_PREVIEW_SESSION_COOKIE = PUBLICATION_SESSION_COOKIE;
export const CMUX_PREVIEW_TRANSACTION_COOKIE = PUBLICATION_TRANSACTION_COOKIE;
export const CMUX_FORWARD_AUTH_TIMEOUT_MS = 1_500;

/** Current public DNS targets from https://www.freestyle.sh/docs/vms/domain-dns. */
export const FREESTYLE_WEB_EDGE_HOST = "beta-web.freestyle.sh";
export const FREESTYLE_CERTIFICATE_NAMESERVER = "beta-dns.freestyle.sh";

const PROTECTED_PREVIEW_COOKIES = [
  CMUX_PREVIEW_SESSION_COOKIE,
  CMUX_PREVIEW_TRANSACTION_COOKIE,
] as const;

export type VmPublicationProviderOperation =
  | "ensureSharedForwardAuth"
  | "createTlsRule"
  | "updateTlsRule"
  | "getTlsRule"
  | "deleteTlsRule"
  | "deleteTlsRulesForHostname"
  | "deleteTlsRulesForHostnames"
  | "reconcileTlsRule"
  | "createDomainVerification"
  | "getDomainVerification"
  | "completeDomainVerification"
  | "requestWildcardCertificate"
  | "getWildcardCertificateStatus"
  | "getCertificateStatus";

export class VmPublicationProviderError extends Data.TaggedError(
  "VmPublicationProviderError",
)<{
  readonly operation: VmPublicationProviderOperation;
  readonly cause: unknown;
}> {}

export type EnsureSharedForwardAuthInput = {
  /** The last shared id CMUX persisted. A missing provider resource is re-created. */
  readonly existingForwardAuthId?: string | null;
  readonly url: string;
  /** Kept write-only: the gateway sends it to Freestyle and never returns it. */
  readonly serviceToken: string;
};

export type EnsureSharedForwardAuthResult = {
  readonly forwardAuthId: string;
  readonly disposition: "created" | "updated";
};

export type PublicationTlsRuleSpec = {
  /** One exact hostname. CMUX publications do not create wildcard rules. */
  readonly hostname: string;
  readonly providerVmId: string;
  readonly port: number;
  /** Omit for public access; set the shared CMUX config for personal/team access. */
  readonly forwardAuthId?: string | null;
};

/** Provider-neutral fields CMUX needs to persist and reconcile a publication rule. */
export type PublicationTlsRule = {
  readonly tlsRuleId: string;
  readonly hostname: string;
  readonly action: string;
  readonly protocol: string;
  readonly sourcePublic: boolean;
  readonly providerVmId: string | null;
  readonly port: number | null;
  readonly forwardAuthId: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
};

export type ReconcileTlsRuleResult = {
  readonly disposition: "created" | "updated" | "unchanged";
  readonly rule: PublicationTlsRule;
};

export type PublicationDnsRecordType =
  | "TXT"
  | "CNAME"
  | "ALIAS"
  | "ANAME"
  | "CNAME_FLATTENING"
  | "NS";

export type PublicationDnsInstruction = {
  readonly purpose: "verification" | "routing" | "certificate";
  readonly recordTypes: readonly PublicationDnsRecordType[];
  /** Fully-qualified name. A DNS UI may ask the user for its zone-relative form. */
  readonly name: string;
  readonly value: string;
};

/**
 * CMUX's stable representation of Freestyle's verification response. The
 * published 0.2.10 SDK calls these fields `id`, `recordName`, and
 * `verificationCode`; those names deliberately stop at this adapter.
 */
export type PublicationDomainVerification = {
  readonly verificationId: string;
  readonly domain: string;
  readonly state: "pending" | "verified";
  readonly verifiedAt: string | null;
  readonly createdAt: string;
  readonly dnsInstructions: {
    readonly verification: PublicationDnsInstruction;
    readonly routing: PublicationDnsInstruction;
    readonly certificate: PublicationDnsInstruction;
  };
};

export type PublicationDomainOwnership = {
  readonly domain: string;
  readonly createdAt: string;
  /** The verification challenge that proved ownership. */
  readonly verificationId: string;
};

export type PublicationCertificate = {
  readonly domain: string;
  readonly wildcard: boolean;
  readonly active: boolean;
  readonly notAfter: string;
  readonly generation: number;
};

export type PublicationCertificateStatus = {
  readonly hostname: string;
  readonly state: "missing" | "pending" | "active";
  readonly ready: boolean;
  /** `platform` is Freestyle's standing `*.style.dev` certificate, not account inventory. */
  readonly source: "none" | "account" | "platform";
  readonly certificate: PublicationCertificate | null;
};

type DomainVerificationInput = {
  /** The owner-scoped base domain CMUX asks Freestyle to verify. */
  readonly domain: string;
  /** The apex or one-label wildcard publication hostname covered by the domain. */
  readonly hostname: string;
};

type GetDomainVerificationInput = {
  readonly domainOrVerificationId: string;
  readonly hostname: string;
};

/** Narrow client surface: tests never need a real Freestyle credential. */
export type VmPublicationFreestyleClient = {
  readonly tls: {
    readonly forwardAuth: {
      readonly create: (
        options: CreateTlsForwardAuthOptions,
      ) => Promise<TlsForwardAuthData>;
      readonly list: () => Promise<ListTlsForwardAuthResult>;
      readonly update: (
        id: string,
        options: CreateTlsForwardAuthOptions,
      ) => Promise<TlsForwardAuthData>;
    };
    readonly rules: {
      readonly create: (options: CreateTlsRuleOptions) => Promise<TlsRuleData>;
      readonly list: (options?: ListTlsRulesOptions) => Promise<ListTlsRulesResult>;
      readonly get: (id: string) => Promise<TlsRuleData>;
      readonly update: (id: string, options: CreateTlsRuleOptions) => Promise<TlsRuleData>;
      readonly delete: (id: string) => Promise<void>;
    };
  };
  readonly domains: {
    readonly verifications: {
      readonly create: (domain: string) => Promise<DomainVerification>;
      readonly get: (domainOrId: string) => Promise<DomainVerification>;
      readonly complete: (domainOrId: string) => Promise<DomainVerified>;
    };
    readonly certificates: {
      readonly list: () => Promise<CertificateInfo[]>;
      readonly createWildcard: (domain: string) => Promise<CertificateInfo>;
    };
  };
};

export type VmPublicationFreestyleClientFactory = () => VmPublicationFreestyleClient;

export type VmPublicationProviderShape = {
  readonly ensureSharedForwardAuth: (
    input: EnsureSharedForwardAuthInput,
  ) => Effect.Effect<EnsureSharedForwardAuthResult, VmPublicationProviderError>;
  readonly createTlsRule: (
    spec: PublicationTlsRuleSpec,
  ) => Effect.Effect<PublicationTlsRule, VmPublicationProviderError>;
  readonly updateTlsRule: (
    tlsRuleId: string,
    spec: PublicationTlsRuleSpec,
  ) => Effect.Effect<PublicationTlsRule, VmPublicationProviderError>;
  readonly getTlsRule: (
    tlsRuleId: string,
  ) => Effect.Effect<PublicationTlsRule | null, VmPublicationProviderError>;
  readonly deleteTlsRule: (
    tlsRuleId: string,
  ) => Effect.Effect<void, VmPublicationProviderError>;
  /** Delete every exact HTTP ingress rule for a hostname, including crash-window duplicates. */
  readonly deleteTlsRulesForHostname: (
    hostname: string,
  ) => Effect.Effect<number, VmPublicationProviderError>;
  /** The same sweep for a batch of hostnames with one provider listing; returns rules deleted. */
  readonly deleteTlsRulesForHostnames: (
    hostnames: readonly string[],
  ) => Effect.Effect<number, VmPublicationProviderError>;
  readonly reconcileTlsRule: (
    tlsRuleId: string | null | undefined,
    spec: PublicationTlsRuleSpec,
  ) => Effect.Effect<ReconcileTlsRuleResult, VmPublicationProviderError>;
  readonly createDomainVerification: (
    input: DomainVerificationInput,
  ) => Effect.Effect<PublicationDomainVerification, VmPublicationProviderError>;
  readonly getDomainVerification: (
    input: GetDomainVerificationInput,
  ) => Effect.Effect<PublicationDomainVerification | null, VmPublicationProviderError>;
  /** `null` when Freestyle could not find the DNS proof yet; the challenge stays open. */
  readonly completeDomainVerification: (
    domainOrVerificationId: string,
  ) => Effect.Effect<PublicationDomainOwnership | null, VmPublicationProviderError>;
  readonly requestWildcardCertificate: (
    domain: string,
  ) => Effect.Effect<PublicationCertificate, VmPublicationProviderError>;
  readonly getWildcardCertificateStatus: (
    domain: string,
  ) => Effect.Effect<PublicationCertificateStatus, VmPublicationProviderError>;
  readonly getCertificateStatus: (
    hostname: string,
  ) => Effect.Effect<PublicationCertificateStatus, VmPublicationProviderError>;
};

export class VmPublicationProvider extends Context.Tag("cmux/VmPublicationProvider")<
  VmPublicationProvider,
  VmPublicationProviderShape
>() {}

function providerEffect<A>(
  operation: VmPublicationProviderOperation,
  run: () => Promise<A>,
): Effect.Effect<A, VmPublicationProviderError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new VmPublicationProviderError({ operation, cause }),
  });
}

function isNotFound(cause: unknown): boolean {
  if (cause instanceof FreestyleApiError) {
    return cause.status === 404 || cause.code === "NOT_FOUND";
  }
  const candidate = cause as { readonly status?: unknown; readonly code?: unknown } | null;
  return candidate?.status === 404 || candidate?.code === "NOT_FOUND";
}

function isVerificationIncomplete(cause: unknown): boolean {
  const status = cause instanceof FreestyleApiError
    ? cause.status
    : (cause as { readonly status?: unknown } | null)?.status;
  return typeof status === "number" &&
    status >= 400 && status < 500 &&
    status !== 401 && status !== 403 && status !== 429;
}

function normalizedExactHostname(value: string): string {
  const hostname = normalizePublicationHostname(value);
  if (!hostname) {
    throw new Error("publication hostname must be one exact DNS hostname");
  }
  return hostname;
}

function normalizedHttpsUrl(value: string): string {
  const parsed = new URL(value);
  if (
    parsed.protocol !== "https:" ||
    parsed.username.length > 0 ||
    parsed.password.length > 0 ||
    parsed.hash.length > 0
  ) {
    throw new Error("forward-auth URL must be an absolute HTTPS URL");
  }
  return parsed.href;
}

export function cmuxForwardAuthOptions(
  input: Pick<EnsureSharedForwardAuthInput, "url" | "serviceToken">,
): CreateTlsForwardAuthOptions {
  if (input.serviceToken.trim().length === 0) {
    throw new Error("forward-auth service token must not be empty");
  }
  return {
    url: normalizedHttpsUrl(input.url),
    headers: { authorization: `Bearer ${input.serviceToken}` },
    timeoutMs: CMUX_FORWARD_AUTH_TIMEOUT_MS,
    protectedCookies: [...PROTECTED_PREVIEW_COOKIES],
  };
}

function canonicalUrlForComparison(value: string): string | null {
  try {
    return new URL(value).href;
  } catch {
    return null;
  }
}

function sameStringSet(left: readonly string[] | undefined, right: readonly string[]): boolean {
  if (!left || left.length !== right.length) return false;
  const values = new Set(left);
  return right.every((value) => values.has(value));
}

function isCmuxForwardAuthConfig(
  config: TlsForwardAuthData,
  options: CreateTlsForwardAuthOptions,
): boolean {
  const headerNames = Object.keys(config.headers ?? {}).map((name) => name.toLowerCase());
  return (
    canonicalUrlForComparison(config.url) === options.url &&
    headerNames.includes("authorization") &&
    sameStringSet(config.protectedCookies, PROTECTED_PREVIEW_COOKIES) &&
    (config.authResponseHeaders?.length ?? 0) === 0
  );
}

export function publicationTlsRuleOptions(
  spec: PublicationTlsRuleSpec,
): CreateTlsRuleOptions {
  const hostname = normalizedExactHostname(spec.hostname);
  const providerVmId = spec.providerVmId.trim();
  if (providerVmId.length === 0) throw new Error("provider VM id must not be empty");
  if (!Number.isInteger(spec.port) || spec.port < 1 || spec.port > 65_535) {
    throw new Error("publication port must be an integer between 1 and 65535");
  }
  const forwardAuthId = spec.forwardAuthId?.trim();
  // A blank id would silently publish a protected publication: `null` is the
  // only spelling of "public", so anything else must be a real config id.
  if (spec.forwardAuthId != null && !forwardAuthId) {
    throw new Error("forward-auth id must not be blank");
  }
  return {
    action: "allow",
    domain: hostname,
    protocol: "http",
    source: { public: true },
    destination: { vmId: providerVmId, port: spec.port },
    ...(forwardAuthId ? { forwardAuth: { id: forwardAuthId } } : {}),
  };
}

function exactKeys(value: object, expected: readonly string[]): boolean {
  const keys = Object.keys(value).sort();
  return keys.length === expected.length && expected.every((key, index) => key === keys[index]);
}

/** Whether the provider rule is exactly the CMUX declaration, including public/protected mode. */
export function tlsRuleMatchesPublication(
  rule: TlsRuleData,
  spec: PublicationTlsRuleSpec,
): boolean {
  const desired = publicationTlsRuleOptions(spec);
  return (
    rule.action === desired.action &&
    normalizedExactHostname(rule.domain) === desired.domain &&
    rule.protocol === "http" &&
    rule.source.public === true &&
    exactKeys(rule.source, ["public"]) &&
    rule.destination.vmId === desired.destination.vmId &&
    rule.destination.port === desired.destination.port &&
    exactKeys(rule.destination, ["port", "vmId"]) &&
    (rule.forwardAuth?.id ?? null) === (desired.forwardAuth?.id ?? null) &&
    (rule.transform?.length ?? 0) === 0
  );
}

function publicationTlsRule(rule: TlsRuleData): PublicationTlsRule {
  return {
    tlsRuleId: rule.id,
    hostname: rule.domain,
    action: rule.action,
    protocol: rule.protocol,
    sourcePublic: rule.source.public === true,
    providerVmId: rule.destination.vmId ?? null,
    port: rule.destination.port ?? null,
    forwardAuthId: rule.forwardAuth?.id ?? null,
    createdAt: rule.createdAt,
    updatedAt: rule.updatedAt,
  };
}

function sameExactHttpIngressHostname(rule: TlsRuleData, hostname: string): boolean {
  let ruleHostname: string;
  try {
    ruleHostname = normalizedExactHostname(rule.domain);
  } catch {
    return false;
  }
  return (
    ruleHostname === hostname &&
    rule.protocol === "http" &&
    rule.source.public === true &&
    exactKeys(rule.source, ["public"])
  );
}

function oldestRule(rules: readonly TlsRuleData[]): TlsRuleData | undefined {
  return [...rules].sort((left, right) => {
    const created = left.createdAt.localeCompare(right.createdAt);
    return created === 0 ? left.id.localeCompare(right.id) : created;
  })[0];
}

function assertHostnameCoveredByDomain(hostname: string, domain: string): void {
  if (hostname === domain) return;
  if (!hostname.endsWith(`.${domain}`)) {
    throw new Error(
      `publication hostname ${hostname} is not covered by verified domain ${domain}`,
    );
  }
  const wildcardLabel = hostname.slice(0, -(domain.length + 1));
  if (!wildcardLabel || wildcardLabel.includes(".")) {
    throw new Error(
      `publication hostname ${hostname} is deeper than the one-label wildcard for ${domain}`,
    );
  }
}

export function publicationDomainVerification(
  verification: DomainVerification,
  requestedHostname: string,
): PublicationDomainVerification {
  const domain = normalizedExactHostname(verification.domain);
  const hostname = normalizedExactHostname(requestedHostname);
  assertHostnameCoveredByDomain(hostname, domain);
  return {
    verificationId: verification.id,
    domain,
    state: verification.state,
    verifiedAt: verification.verifiedAt,
    createdAt: verification.createdAt,
    dnsInstructions: {
      verification: {
        purpose: "verification",
        recordTypes: ["TXT"],
        name: verification.recordName,
        value: verification.verificationCode,
      },
      routing: publicationRoutingDnsInstruction(hostname, domain),
      certificate: {
        purpose: "certificate",
        recordTypes: ["NS"],
        name: `_acme-challenge.${domain}`,
        value: FREESTYLE_CERTIFICATE_NAMESERVER,
      },
    },
  };
}

/** DNS routing for one exact host covered by a CMUX-owner-scoped zone. */
export function publicationRoutingDnsInstruction(
  requestedHostname: string,
  verifiedDomain: string,
): PublicationDnsInstruction {
  const hostname = normalizedExactHostname(requestedHostname);
  const domain = normalizedExactHostname(verifiedDomain);
  assertHostnameCoveredByDomain(hostname, domain);
  return {
    purpose: "routing",
    recordTypes: hostname === domain
      ? ["ALIAS", "ANAME", "CNAME_FLATTENING"]
      : ["CNAME"],
    name: hostname,
    value: FREESTYLE_WEB_EDGE_HOST,
  };
}

/**
 * One-label `style.dev` names are Freestyle's free platform zone: no
 * verification, no DNS, and the platform wildcard certificate. A CMUX-owned
 * generated zone such as `cmux.sh` is ordinary verified account inventory.
 */
export function isFreestylePlatformHostname(value: string): boolean {
  const hostname = normalizedExactHostname(value);
  const labels = hostname.split(".");
  return labels.length === 3 && labels[1] === "style" && labels[2] === "dev";
}

export function certificateCoversHostname(
  certificate: Pick<CertificateInfo, "domain" | "wildcard">,
  requestedHostname: string,
): boolean {
  const hostname = normalizedExactHostname(requestedHostname);
  const domain = normalizedExactHostname(certificate.domain);
  if (!certificate.wildcard) return hostname === domain;
  if (!hostname.endsWith(`.${domain}`)) return false;
  return hostname.slice(0, -(domain.length + 1)).includes(".") === false;
}

function publicationCertificate(certificate: CertificateInfo): PublicationCertificate {
  return {
    domain: certificate.domain,
    wildcard: certificate.wildcard,
    active: certificate.active,
    notAfter: certificate.notAfter,
    generation: certificate.generation,
  };
}

function accountCertificateStatus(
  hostname: string,
  certificates: readonly CertificateInfo[],
): PublicationCertificateStatus {
  const covering = certificates.filter((certificate) =>
    certificateCoversHostname(certificate, hostname),
  );
  const exactActive = covering.find((certificate) => !certificate.wildcard && certificate.active);
  const wildcardActive = covering.find((certificate) => certificate.wildcard && certificate.active);
  const candidate = exactActive ?? wildcardActive ?? covering.find((certificate) => !certificate.wildcard) ?? covering[0];
  if (!candidate) {
    return { hostname, state: "missing", ready: false, source: "none", certificate: null };
  }
  return {
    hostname,
    state: candidate.active ? "active" : "pending",
    ready: candidate.active,
    source: "account",
    certificate: publicationCertificate(candidate),
  };
}

const TLS_RULE_LIST_PAGE_SIZE = 100;
const TLS_RULE_LIST_MAX_PAGES = 1_000;

/**
 * Freestyle lists rules newest-first in pages. Rules span every CMUX account,
 * so a single page can never be assumed to hold the hostname being swept or
 * reconciled; walk until `totalCount` is reached, deduplicating by id in case
 * a concurrent create shifts the offsets between pages.
 */
async function listAllTlsRules(
  client: VmPublicationFreestyleClient,
): Promise<TlsRuleData[]> {
  const rules: TlsRuleData[] = [];
  const seen = new Set<string>();
  for (let page = 0; page < TLS_RULE_LIST_MAX_PAGES; page++) {
    const listed = await client.tls.rules.list({
      limit: TLS_RULE_LIST_PAGE_SIZE,
      offset: page * TLS_RULE_LIST_PAGE_SIZE,
    });
    for (const rule of listed.rules) {
      if (seen.has(rule.id)) continue;
      seen.add(rule.id);
      rules.push(rule);
    }
    if (listed.rules.length === 0 || rules.length >= listed.totalCount) return rules;
  }
  throw new Error("Freestyle TLS rule listing exceeded its page limit");
}

async function deleteExactHostnameRules(
  client: VmPublicationFreestyleClient,
  hostnames: readonly string[],
): Promise<number> {
  const targets = [...new Set(hostnames.map(normalizedExactHostname))];
  if (targets.length === 0) return 0;
  const ruleIds = (await listAllTlsRules(client))
    .filter((rule) => targets.some((hostname) => sameExactHttpIngressHostname(rule, hostname)))
    .map((rule) => rule.id);
  for (const ruleId of ruleIds) {
    try {
      await client.tls.rules.delete(ruleId);
    } catch (cause) {
      if (!isNotFound(cause)) throw cause;
    }
  }
  return ruleIds.length;
}

export function makeVmPublicationProvider(
  createClient: VmPublicationFreestyleClientFactory = () => freestyleClient(),
): VmPublicationProviderShape {
  return {
    ensureSharedForwardAuth: (input) =>
      providerEffect("ensureSharedForwardAuth", async () => {
        const client = createClient();
        const options = cmuxForwardAuthOptions(input);
        const existingId = input.existingForwardAuthId?.trim();
        if (existingId) {
          try {
            const updated = await client.tls.forwardAuth.update(existingId, options);
            return { forwardAuthId: updated.id, disposition: "updated" as const };
          } catch (cause) {
            if (!isNotFound(cause)) throw cause;
          }
        }

        // Recover the account-wide singleton after local state loss instead of
        // creating one config per publication. Header values are redacted on
        // read, so every adopted config is updated to rotate the real token.
        const listed = await client.tls.forwardAuth.list();
        const reusable = listed.configs.find((config) =>
          isCmuxForwardAuthConfig(config, options),
        );
        if (reusable) {
          const updated = await client.tls.forwardAuth.update(reusable.id, options);
          return { forwardAuthId: updated.id, disposition: "updated" as const };
        }

        const created = await client.tls.forwardAuth.create(options);
        return { forwardAuthId: created.id, disposition: "created" as const };
      }),

    // Creating an exact custom-domain rule is also Freestyle's certificate
    // issuance trigger. Persist its id first, then poll getCertificateStatus.
    createTlsRule: (spec) =>
      providerEffect("createTlsRule", async () =>
        publicationTlsRule(await createClient().tls.rules.create(publicationTlsRuleOptions(spec))),
      ),

    updateTlsRule: (tlsRuleId, spec) =>
      providerEffect("updateTlsRule", async () =>
        publicationTlsRule(
          await createClient().tls.rules.update(tlsRuleId, publicationTlsRuleOptions(spec)),
        ),
      ),

    getTlsRule: (tlsRuleId) =>
      providerEffect("getTlsRule", async () => {
        try {
          return publicationTlsRule(await createClient().tls.rules.get(tlsRuleId));
        } catch (cause) {
          if (isNotFound(cause)) return null;
          throw cause;
        }
      }),

    deleteTlsRule: (tlsRuleId) =>
      providerEffect("deleteTlsRule", async () => {
        try {
          await createClient().tls.rules.delete(tlsRuleId);
        } catch (cause) {
          if (!isNotFound(cause)) throw cause;
        }
      }),

    deleteTlsRulesForHostname: (value) =>
      providerEffect("deleteTlsRulesForHostname", () =>
        deleteExactHostnameRules(createClient(), [value]),
      ),

    deleteTlsRulesForHostnames: (values) =>
      providerEffect("deleteTlsRulesForHostnames", () =>
        deleteExactHostnameRules(createClient(), values),
      ),

    reconcileTlsRule: (tlsRuleId, spec) =>
      providerEffect("reconcileTlsRule", async () => {
        const client = createClient();
        const id = tlsRuleId?.trim();
        const desired = publicationTlsRuleOptions(spec);
        let persisted: TlsRuleData | null = null;
        if (id) {
          try {
            persisted = await client.tls.rules.get(id);
          } catch (cause) {
            if (!isNotFound(cause)) throw cause;
          }
        }

        // Provider creation and CMUX persistence are separate commits. If the
        // first succeeded and the process died before the second, recover that
        // exact-domain rule instead of creating a duplicate. Equal Freestyle
        // ingress matches resolve oldest-first, so converge the oldest and
        // remove every shadow that could otherwise reappear after deletion.
        const listed = await listAllTlsRules(client);
        const byId = new Map(listed.map((rule) => [rule.id, rule]));
        if (persisted) byId.set(persisted.id, persisted);
        const candidates = [...byId.values()].filter((rule) =>
          sameExactHttpIngressHostname(rule, desired.domain),
        );
        const recovered = oldestRule(candidates);
        if (recovered) {
          const canonical = tlsRuleMatchesPublication(recovered, spec)
            ? recovered
            : await client.tls.rules.update(recovered.id, desired);
          const staleIds = new Set(
            candidates
              .filter((candidate) => candidate.id !== canonical.id)
              .map((candidate) => candidate.id),
          );
          if (persisted && persisted.id !== canonical.id) staleIds.add(persisted.id);
          for (const staleId of staleIds) {
            try {
              await client.tls.rules.delete(staleId);
            } catch (cause) {
              if (!isNotFound(cause)) throw cause;
            }
          }
          const changed =
            canonical !== recovered ||
            staleIds.size > 0 ||
            id !== canonical.id;
          return {
            disposition: changed ? "updated" as const : "unchanged" as const,
            rule: publicationTlsRule(canonical),
          };
        }

        if (persisted) {
          const updated = await client.tls.rules.update(persisted.id, desired);
          return { disposition: "updated" as const, rule: publicationTlsRule(updated) };
        }

        const created = await client.tls.rules.create(desired);
        return { disposition: "created" as const, rule: publicationTlsRule(created) };
      }),

    createDomainVerification: (input) =>
      providerEffect("createDomainVerification", async () => {
        const domain = normalizedExactHostname(input.domain);
        const verification = await createClient().domains.verifications.create(domain);
        return publicationDomainVerification(verification, input.hostname);
      }),

    getDomainVerification: (input) =>
      providerEffect("getDomainVerification", async () => {
        try {
          const verification = await createClient().domains.verifications.get(
            input.domainOrVerificationId,
          );
          return publicationDomainVerification(verification, input.hostname);
        } catch (cause) {
          if (isNotFound(cause)) return null;
          throw cause;
        }
      }),

    completeDomainVerification: (domainOrVerificationId) =>
      providerEffect("completeDomainVerification", async () => {
        let ownership: DomainVerified;
        try {
          ownership = await createClient().domains.verifications.complete(
            domainOrVerificationId,
          );
        } catch (cause) {
          // A rejected completion means the TXT proof is not visible yet (or
          // the challenge was withdrawn); the caller reports "still pending"
          // instead of a provider outage. Auth, throttling, and 5xx still fail.
          if (isVerificationIncomplete(cause)) return null;
          throw cause;
        }
        return {
          domain: ownership.domain,
          createdAt: ownership.createdAt,
          verificationId: ownership.verifiedBy,
        };
      }),

    requestWildcardCertificate: (value) =>
      providerEffect("requestWildcardCertificate", async () => {
        const domain = normalizedExactHostname(value);
        return publicationCertificate(
          await createClient().domains.certificates.createWildcard(domain),
        );
      }),

    getWildcardCertificateStatus: (value) =>
      providerEffect("getWildcardCertificateStatus", async () => {
        const domain = normalizedExactHostname(value);
        const certificates = await createClient().domains.certificates.list();
        const candidate = certificates.find((certificate) =>
          certificate.wildcard && normalizedExactHostname(certificate.domain) === domain,
        );
        if (!candidate) {
          return {
            hostname: `*.${domain}`,
            state: "missing" as const,
            ready: false,
            source: "none" as const,
            certificate: null,
          };
        }
        return {
          hostname: `*.${domain}`,
          state: candidate.active ? "active" as const : "pending" as const,
          ready: candidate.active,
          source: "account" as const,
          certificate: publicationCertificate(candidate),
        };
      }),

    getCertificateStatus: (value) =>
      providerEffect("getCertificateStatus", async () => {
        const hostname = normalizedExactHostname(value);
        // Platform names use Freestyle's standing wildcard, which is ready
        // without an account certificate row or DNS setup. Every other zone,
        // including the CMUX generated zone, is account inventory.
        if (isFreestylePlatformHostname(hostname)) {
          return {
            hostname,
            state: "active" as const,
            ready: true,
            source: "platform" as const,
            certificate: null,
          };
        }
        const certificates = await createClient().domains.certificates.list();
        return accountCertificateStatus(hostname, certificates);
      }),
  };
}

export const VmPublicationProviderLive = Layer.succeed(
  VmPublicationProvider,
  makeVmPublicationProvider(),
);
