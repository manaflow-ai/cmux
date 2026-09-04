import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  FreestyleApiError,
  type CertificateInfo,
  type CreateTlsForwardAuthOptions,
  type CreateTlsRuleOptions,
  type DomainVerification,
  type ListTlsRulesOptions,
  type TlsForwardAuthData,
  type TlsRuleData,
} from "freestyle";
import {
  CMUX_FORWARD_AUTH_TIMEOUT_MS,
  CMUX_PREVIEW_SESSION_COOKIE,
  CMUX_PREVIEW_TRANSACTION_COOKIE,
  FREESTYLE_CERTIFICATE_NAMESERVER,
  FREESTYLE_WEB_EDGE_HOST,
  VmPublicationProviderError,
  makeVmPublicationProvider,
  type VmPublicationFreestyleClient,
} from "../services/vm-publications/provider";

const CREATED_AT = "2026-09-02T12:00:00.000Z";
const UPDATED_AT = "2026-09-02T12:01:00.000Z";

function forwardAuthData(
  id: string,
  overrides: Partial<TlsForwardAuthData> = {},
): TlsForwardAuthData {
  return {
    id,
    accountId: "acct-cmux",
    url: "https://cmux.com/api/freestyle/forward-auth",
    headers: { authorization: "***" },
    timeoutMs: CMUX_FORWARD_AUTH_TIMEOUT_MS,
    protectedCookies: [CMUX_PREVIEW_SESSION_COOKIE, CMUX_PREVIEW_TRANSACTION_COOKIE],
    redacted: true,
    createdAt: CREATED_AT,
    updatedAt: UPDATED_AT,
    ...overrides,
  };
}

function tlsRuleData(
  id: string,
  options: CreateTlsRuleOptions,
  overrides: Partial<TlsRuleData> = {},
): TlsRuleData {
  return {
    id,
    accountId: "acct-cmux",
    action: options.action,
    domain: options.domain,
    protocol: options.protocol ?? "http",
    source: options.source,
    destination: options.destination,
    ...(options.transform ? { transform: options.transform } : {}),
    ...(options.forwardAuth ? { forwardAuth: options.forwardAuth } : {}),
    dependencies: [{ kind: "vm", id: options.destination.vmId ?? "vm-unknown" }],
    createdAt: CREATED_AT,
    updatedAt: UPDATED_AT,
    ...overrides,
  };
}

function domainVerification(
  overrides: Partial<DomainVerification> = {},
): DomainVerification {
  return {
    id: "verification-1",
    domain: "example.com",
    verificationCode: "freestyle-verification=secret-code",
    recordName: "_freestyle-verification.example.com",
    state: "pending",
    verifiedAt: null,
    createdAt: CREATED_AT,
    ...overrides,
  };
}

function unused(message: string): never {
  throw new Error(`unexpected fake call: ${message}`);
}

function fakeClient(
  overrides: {
    readonly forwardAuthCreate?: (options: CreateTlsForwardAuthOptions) => Promise<TlsForwardAuthData>;
    readonly forwardAuthList?: () => Promise<{
      configs: TlsForwardAuthData[];
      totalCount: number;
    }>;
    readonly forwardAuthUpdate?: (
      id: string,
      options: CreateTlsForwardAuthOptions,
    ) => Promise<TlsForwardAuthData>;
    readonly tlsCreate?: (options: CreateTlsRuleOptions) => Promise<TlsRuleData>;
    readonly tlsList?: (
      options?: ListTlsRulesOptions,
    ) => Promise<{ rules: TlsRuleData[]; totalCount: number }>;
    readonly tlsGet?: (id: string) => Promise<TlsRuleData>;
    readonly tlsUpdate?: (id: string, options: CreateTlsRuleOptions) => Promise<TlsRuleData>;
    readonly tlsDelete?: (id: string) => Promise<void>;
    readonly verificationCreate?: (domain: string) => Promise<DomainVerification>;
    readonly verificationGet?: (domainOrId: string) => Promise<DomainVerification>;
    readonly verificationComplete?: (domainOrId: string) => Promise<{
      domain: string;
      createdAt: string;
      verifiedBy: string;
    }>; 
    readonly certificateList?: () => Promise<CertificateInfo[]>;
    readonly wildcardCreate?: (domain: string) => Promise<CertificateInfo>;
  } = {},
): VmPublicationFreestyleClient {
  return {
    tls: {
      forwardAuth: {
        create: overrides.forwardAuthCreate ?? (async () => unused("forwardAuth.create")),
        list: overrides.forwardAuthList ?? (async () => unused("forwardAuth.list")),
        update: overrides.forwardAuthUpdate ?? (async () => unused("forwardAuth.update")),
      },
      rules: {
        create: overrides.tlsCreate ?? (async () => unused("tls.rules.create")),
        list: overrides.tlsList ?? (async () => unused("tls.rules.list")),
        get: overrides.tlsGet ?? (async () => unused("tls.rules.get")),
        update: overrides.tlsUpdate ?? (async () => unused("tls.rules.update")),
        delete: overrides.tlsDelete ?? (async () => unused("tls.rules.delete")),
      },
    },
    domains: {
      verifications: {
        create: overrides.verificationCreate ?? (async () => unused("verifications.create")),
        get: overrides.verificationGet ?? (async () => unused("verifications.get")),
        complete: overrides.verificationComplete ?? (async () => unused("verifications.complete")),
      },
      certificates: {
        list: overrides.certificateList ?? (async () => unused("certificates.list")),
        createWildcard: overrides.wildcardCreate ?? (async () => unused("certificates.createWildcard")),
      },
    },
  };
}

describe("VM publication Freestyle provider", () => {
  test("adopts and rotates the reusable account-wide forward-auth config", async () => {
    const updates: Array<{ id: string; options: CreateTlsForwardAuthOptions }> = [];
    const client = fakeClient({
      forwardAuthList: async () => ({
        configs: [forwardAuthData("forward-auth-shared")],
        totalCount: 1,
      }),
      forwardAuthUpdate: async (id, options) => {
        updates.push({ id, options });
        return forwardAuthData(id, { url: options.url });
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    const result = await Effect.runPromise(
      provider.ensureSharedForwardAuth({
        url: "https://cmux.com/api/freestyle/forward-auth",
        serviceToken: "new-secret",
      }),
    );

    expect(result).toEqual({
      forwardAuthId: "forward-auth-shared",
      disposition: "updated",
    });
    expect(updates).toEqual([
      {
        id: "forward-auth-shared",
        options: {
          url: "https://cmux.com/api/freestyle/forward-auth",
          headers: { authorization: "Bearer new-secret" },
          timeoutMs: CMUX_FORWARD_AUTH_TIMEOUT_MS,
          protectedCookies: [CMUX_PREVIEW_SESSION_COOKIE, CMUX_PREVIEW_TRANSACTION_COOKIE],
        },
      },
    ]);
    expect(result).not.toHaveProperty("serviceToken");
  });

  test("recreates a shared config when the persisted provider id disappeared", async () => {
    const calls: string[] = [];
    const client = fakeClient({
      forwardAuthUpdate: async (id) => {
        calls.push(`update:${id}`);
        throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "gone" });
      },
      forwardAuthList: async () => {
        calls.push("list");
        return { configs: [], totalCount: 0 };
      },
      forwardAuthCreate: async (options) => {
        calls.push("create");
        return forwardAuthData("forward-auth-new", { url: options.url });
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(
        provider.ensureSharedForwardAuth({
          existingForwardAuthId: "forward-auth-old",
          url: "https://cmux.com/api/freestyle/forward-auth",
          serviceToken: "secret",
        }),
      ),
    ).resolves.toEqual({
      forwardAuthId: "forward-auth-new",
      disposition: "created",
    });
    expect(calls).toEqual(["update:forward-auth-old", "list", "create"]);
  });

  test("wraps provider failures with the operation and does not hide non-404 errors", async () => {
    const cause = new FreestyleApiError(503, {
      code: "UPSTREAM_UNAVAILABLE",
      message: "unavailable",
    });
    const provider = makeVmPublicationProvider(() =>
      fakeClient({
        forwardAuthUpdate: async () => {
          throw cause;
        },
      }),
    );

    const error = await Effect.runPromise(
      Effect.flip(
        provider.ensureSharedForwardAuth({
          existingForwardAuthId: "forward-auth-1",
          url: "https://cmux.com/api/freestyle/forward-auth",
          serviceToken: "secret",
        }),
      ),
    );
    expect(error).toBeInstanceOf(VmPublicationProviderError);
    expect(error.operation).toBe("ensureSharedForwardAuth");
    expect(error.cause).toBe(cause);
  });

  test("creates exact public and protected HTTP ingress rules", async () => {
    const created: CreateTlsRuleOptions[] = [];
    const client = fakeClient({
      tlsCreate: async (options) => {
        created.push(options);
        return tlsRuleData(`tls-rule-${created.length}`, options);
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    const protectedRule = await Effect.runPromise(
      provider.createTlsRule({
        hostname: "App.Example.com.",
        providerVmId: "vm-1",
        port: 3_000,
        forwardAuthId: "forward-auth-1",
      }),
    );
    const publicRule = await Effect.runPromise(
      provider.createTlsRule({
        hostname: "public.example.com",
        providerVmId: "vm-2",
        port: 8_080,
      }),
    );

    expect(protectedRule).toMatchObject({
      tlsRuleId: "tls-rule-1",
      hostname: "app.example.com",
      providerVmId: "vm-1",
      port: 3_000,
      forwardAuthId: "forward-auth-1",
    });
    expect(publicRule.forwardAuthId).toBeNull();
    expect(created).toEqual([
      {
        action: "allow",
        domain: "app.example.com",
        protocol: "http",
        source: { public: true },
        destination: { vmId: "vm-1", port: 3_000 },
        forwardAuth: { id: "forward-auth-1" },
      },
      {
        action: "allow",
        domain: "public.example.com",
        protocol: "http",
        source: { public: true },
        destination: { vmId: "vm-2", port: 8_080 },
      },
    ]);
  });

  test("reconciliation leaves an exact match alone and replaces drift in place", async () => {
    const desired: CreateTlsRuleOptions = {
      action: "allow",
      domain: "app.example.com",
      protocol: "http",
      source: { public: true },
      destination: { vmId: "vm-1", port: 3_000 },
      forwardAuth: { id: "forward-auth-1" },
    };
    const updates: Array<{ id: string; options: CreateTlsRuleOptions }> = [];
    let current = tlsRuleData("tls-rule-1", desired);
    const client = fakeClient({
      tlsGet: async () => current,
      tlsList: async () => ({ rules: [current], totalCount: 1 }),
      tlsUpdate: async (id, options) => {
        updates.push({ id, options });
        current = tlsRuleData(id, options);
        return current;
      },
    });
    const provider = makeVmPublicationProvider(() => client);
    const spec = {
      hostname: "app.example.com",
      providerVmId: "vm-1",
      port: 3_000,
      forwardAuthId: "forward-auth-1",
    } as const;

    await expect(Effect.runPromise(provider.reconcileTlsRule("tls-rule-1", spec))).resolves.toMatchObject({
      disposition: "unchanged",
      rule: { tlsRuleId: "tls-rule-1" },
    });
    current = tlsRuleData("tls-rule-1", { ...desired, forwardAuth: undefined });
    await expect(Effect.runPromise(provider.reconcileTlsRule("tls-rule-1", spec))).resolves.toMatchObject({
      disposition: "updated",
      rule: { tlsRuleId: "tls-rule-1", forwardAuthId: "forward-auth-1" },
    });
    expect(updates).toEqual([{ id: "tls-rule-1", options: desired }]);
  });

  test("reconciliation recovers the oldest effective rule and removes retry duplicates", async () => {
    const desired: CreateTlsRuleOptions = {
      action: "allow",
      domain: "app.example.com",
      protocol: "http",
      source: { public: true },
      destination: { vmId: "vm-1", port: 3_000 },
      forwardAuth: { id: "forward-auth-1" },
    };
    const oldest = tlsRuleData(
      "tls-rule-oldest",
      { ...desired, destination: { vmId: "vm-wrong", port: 9_000 } },
      { createdAt: "2026-09-02T11:00:00.000Z" },
    );
    const retryDuplicate = tlsRuleData(
      "tls-rule-retry",
      desired,
      { createdAt: "2026-09-02T12:00:00.000Z" },
    );
    const updated: string[] = [];
    const deleted: string[] = [];
    const client = fakeClient({
      // Freestyle lists newest first, while equal ingress matches oldest first.
      tlsList: async () => ({ rules: [retryDuplicate, oldest], totalCount: 2 }),
      tlsUpdate: async (id, options) => {
        updated.push(id);
        return tlsRuleData(id, options, { createdAt: oldest.createdAt });
      },
      tlsDelete: async (id) => {
        deleted.push(id);
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(
        provider.reconcileTlsRule(null, {
          hostname: "app.example.com",
          providerVmId: "vm-1",
          port: 3_000,
          forwardAuthId: "forward-auth-1",
        }),
      ),
    ).resolves.toMatchObject({
      disposition: "updated",
      rule: {
        tlsRuleId: "tls-rule-oldest",
        providerVmId: "vm-1",
        port: 3_000,
        forwardAuthId: "forward-auth-1",
      },
    });
    expect(updated).toEqual(["tls-rule-oldest"]);
    expect(deleted).toEqual(["tls-rule-retry"]);
  });

  test("missing TLS resources are recreated by reconciliation and idempotent cleanup", async () => {
    const deleted: string[] = [];
    const client = fakeClient({
      tlsGet: async () => {
        throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "gone" });
      },
      tlsList: async () => ({ rules: [], totalCount: 0 }),
      tlsCreate: async (options) => tlsRuleData("tls-rule-new", options),
      tlsDelete: async (id) => {
        deleted.push(id);
        throw new FreestyleApiError(404, { code: "NOT_FOUND", message: "gone" });
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(Effect.runPromise(provider.getTlsRule("missing"))).resolves.toBeNull();
    await expect(
      Effect.runPromise(
        provider.reconcileTlsRule("missing", {
          hostname: "app.example.com",
          providerVmId: "vm-1",
          port: 3_000,
        }),
      ),
    ).resolves.toMatchObject({
      disposition: "created",
      rule: { tlsRuleId: "tls-rule-new" },
    });
    await expect(Effect.runPromise(provider.deleteTlsRule("missing"))).resolves.toBeUndefined();
    expect(deleted).toEqual(["missing"]);
  });

  test("deletes every exact hostname rule left by an interrupted publication create", async () => {
    const desired: CreateTlsRuleOptions = {
      action: "allow",
      domain: "app.example.com",
      protocol: "http",
      source: { public: true },
      destination: { vmId: "vm-1", port: 3_000 },
    };
    const deleted: string[] = [];
    const client = fakeClient({
      tlsList: async () => ({
        rules: [
          tlsRuleData("tls-rule-persisted", desired),
          tlsRuleData("tls-rule-crash-duplicate", desired),
          tlsRuleData("tls-rule-other-host", { ...desired, domain: "other.example.com" }),
          tlsRuleData("tls-rule-private", desired, {
            source: { public: false } as never,
          }),
        ],
        totalCount: 4,
      }),
      tlsDelete: async (id) => {
        deleted.push(id);
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(provider.deleteTlsRulesForHostname("App.Example.com.")),
    ).resolves.toBe(2);
    expect(deleted).toEqual(["tls-rule-persisted", "tls-rule-crash-duplicate"]);
  });

  test("walks every provider page before sweeping or reconciling hostname rules", async () => {
    const desired: CreateTlsRuleOptions = {
      action: "allow",
      domain: "app.example.com",
      protocol: "http",
      source: { public: true },
      destination: { vmId: "vm-1", port: 3_000 },
    };
    const firstPage = Array.from({ length: 100 }, (_, index) =>
      tlsRuleData(`tls-rule-other-${index}`, { ...desired, domain: `other-${index}.example.com` }));
    const secondPage = [
      tlsRuleData("tls-rule-target", desired),
      tlsRuleData("tls-rule-sibling", { ...desired, domain: "sibling.example.com" }),
    ];
    const everyRule = [...firstPage, ...secondPage];
    const pages: ListTlsRulesOptions[] = [];
    const deleted: string[] = [];
    const client = fakeClient({
      tlsList: async (options = {}) => {
        pages.push(options);
        const offset = options.offset ?? 0;
        const limit = options.limit ?? everyRule.length;
        return { rules: everyRule.slice(offset, offset + limit), totalCount: everyRule.length };
      },
      tlsDelete: async (id) => {
        deleted.push(id);
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(
        provider.deleteTlsRulesForHostnames(["app.example.com", "Sibling.Example.com."]),
      ),
    ).resolves.toBe(2);
    expect(deleted).toEqual(["tls-rule-target", "tls-rule-sibling"]);
    expect(pages).toEqual([{ limit: 100, offset: 0 }, { limit: 100, offset: 100 }]);

    pages.length = 0;
    const reconciled = await Effect.runPromise(provider.reconcileTlsRule(null, {
      hostname: "app.example.com",
      providerVmId: "vm-1",
      port: 3_000,
    }));
    expect(reconciled.rule.tlsRuleId).toBe("tls-rule-target");
    expect(pages).toHaveLength(2);
    expect(await Effect.runPromise(provider.deleteTlsRulesForHostnames([]))).toBe(0);
  });

  test("repeats an unstable rule scan and fails closed when it never settles", async () => {
    const desired: CreateTlsRuleOptions = {
      action: "allow",
      domain: "app.example.com",
      protocol: "http",
      source: { public: true },
      destination: { vmId: "vm-1", port: 3_000 },
    };
    const other = (index: number) =>
      tlsRuleData(`tls-rule-${index}`, { ...desired, domain: `r${index}.example.com` });
    const stable = [
      ...Array.from({ length: 100 }, (_, index) => other(index)),
      tlsRuleData("tls-rule-target", desired),
    ];
    let calls = 0;
    const deleted: string[] = [];
    const client = fakeClient({
      // The first scan sees a rule inserted between its two pages (the total
      // grows and the second page repeats an id); the second scan is stable.
      tlsList: async (options = {}) => {
        calls += 1;
        const offset = options.offset ?? 0;
        if (calls === 1) return { rules: stable.slice(0, 100), totalCount: 101 };
        if (calls === 2) return { rules: [stable[99]!, stable[100]!], totalCount: 102 };
        return { rules: stable.slice(offset, offset + 100), totalCount: stable.length };
      },
      tlsDelete: async (id) => {
        deleted.push(id);
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(provider.deleteTlsRulesForHostnames(["app.example.com"])),
    ).resolves.toBe(1);
    expect(deleted).toEqual(["tls-rule-target"]);
    expect(calls).toBe(4);

    const neverSettles = makeVmPublicationProvider(() => fakeClient({
      tlsList: async () => {
        calls += 1;
        return { rules: [other(calls)], totalCount: calls + 5 };
      },
    }));
    const error = await Effect.runPromise(
      Effect.flip(neverSettles.deleteTlsRulesForHostnames(["app.example.com"])),
    );
    expect(error).toBeInstanceOf(VmPublicationProviderError);
    expect(String((error.cause as Error).message)).toContain("kept changing");
  });

  test("refuses a blank forward-auth id rather than publishing a protected rule", async () => {
    const provider = makeVmPublicationProvider(() => fakeClient());
    const error = await Effect.runPromise(Effect.flip(provider.createTlsRule({
      hostname: "app.example.com",
      providerVmId: "vm-1",
      port: 3_000,
      forwardAuthId: "   ",
    })));
    expect(error).toBeInstanceOf(VmPublicationProviderError);
    expect(error.operation).toBe("createTlsRule");
    expect(String((error.cause as Error).message)).toContain("blank");
  });

  test("normalizes SDK verification fields into complete TXT, routing, and certificate DNS instructions", async () => {
    const createdDomains: string[] = [];
    const client = fakeClient({
      verificationCreate: async (domain) => {
        createdDomains.push(domain);
        return domainVerification({
          domain,
          recordName: `_freestyle-verification.${domain}`,
        });
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    const verification = await Effect.runPromise(
      provider.createDomainVerification({
        domain: "Example.com.",
        hostname: "Preview.Example.com.",
      }),
    );

    expect(createdDomains).toEqual(["example.com"]);
    expect(verification).toEqual({
      verificationId: "verification-1",
      domain: "example.com",
      state: "pending",
      verifiedAt: null,
      createdAt: CREATED_AT,
      dnsInstructions: {
        verification: {
          purpose: "verification",
          recordTypes: ["TXT"],
          name: "_freestyle-verification.example.com",
          value: "freestyle-verification=secret-code",
        },
        routing: {
          purpose: "routing",
          recordTypes: ["CNAME"],
          name: "preview.example.com",
          value: FREESTYLE_WEB_EDGE_HOST,
        },
        certificate: {
          purpose: "certificate",
          recordTypes: ["NS"],
          name: "_acme-challenge.example.com",
          value: FREESTYLE_CERTIFICATE_NAMESERVER,
        },
      },
    });
  });

  test("returns routing alternatives and maps completed verification ownership", async () => {
    const completed: string[] = [];
    const client = fakeClient({
      verificationGet: async () => domainVerification(),
      verificationComplete: async (domainOrId) => {
        completed.push(domainOrId);
        return {
          domain: "example.com",
          createdAt: CREATED_AT,
          verifiedBy: "verification-1",
        };
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    const verification = await Effect.runPromise(
      provider.getDomainVerification({
        domainOrVerificationId: "verification-1",
        hostname: "example.com",
      }),
    );
    expect(verification?.dnsInstructions.routing.recordTypes).toEqual([
      "ALIAS",
      "ANAME",
      "CNAME_FLATTENING",
    ]);
    await expect(
      Effect.runPromise(provider.completeDomainVerification("verification-1")),
    ).resolves.toEqual({
      domain: "example.com",
      createdAt: CREATED_AT,
      verificationId: "verification-1",
    });
    expect(completed).toEqual(["verification-1"]);
  });

  test("treats a rejected verification completion as still pending", async () => {
    // Observed live from Freestyle: a missing TXT proof is `400 VERIFICATION_FAILED`.
    let failure: { status: number; code: string } = { status: 400, code: "VERIFICATION_FAILED" };
    const client = fakeClient({
      verificationComplete: async () => {
        throw new FreestyleApiError(failure.status, {
          code: failure.code,
          message: "TXT lookup failed: no records found",
        });
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    for (failure of [
      { status: 400, code: "VERIFICATION_FAILED" },
      { status: 404, code: "NOT_FOUND" },
    ]) {
      await expect(
        Effect.runPromise(provider.completeDomainVerification("verification-1")),
      ).resolves.toBeNull();
    }
    for (failure of [
      { status: 400, code: "BAD_REQUEST" },
      { status: 401, code: "UNAUTHORIZED" },
      { status: 409, code: "CONFLICT" },
      { status: 429, code: "RATE_LIMITED" },
      { status: 503, code: "UNAVAILABLE" },
    ]) {
      const error = await Effect.runPromise(
        Effect.flip(provider.completeDomainVerification("verification-1")),
      );
      expect(error).toBeInstanceOf(VmPublicationProviderError);
      expect(error.operation).toBe("completeDomainVerification");
    }
  });

  test("requests and polls the reusable wildcard certificate for a verified zone", async () => {
    const requested: string[] = [];
    let certificates: CertificateInfo[] = [];
    const pending: CertificateInfo = {
      domain: "example.com",
      wildcard: true,
      active: false,
      notAfter: CREATED_AT,
      generation: 0,
    };
    const provider = makeVmPublicationProvider(() => fakeClient({
      wildcardCreate: async (domain) => {
        requested.push(domain);
        return pending;
      },
      certificateList: async () => certificates,
    }));

    await expect(Effect.runPromise(
      provider.requestWildcardCertificate("Example.com."),
    )).resolves.toMatchObject({ domain: "example.com", wildcard: true, active: false });
    await expect(Effect.runPromise(
      provider.getWildcardCertificateStatus("example.com"),
    )).resolves.toMatchObject({
      hostname: "*.example.com",
      state: "missing",
      ready: false,
      certificate: null,
    });

    certificates = [{ ...pending, active: true, generation: 1 }];
    await expect(Effect.runPromise(
      provider.getWildcardCertificateStatus("example.com"),
    )).resolves.toMatchObject({
      hostname: "*.example.com",
      state: "active",
      ready: true,
      certificate: { domain: "example.com", wildcard: true, active: true },
    });
    expect(requested).toEqual(["example.com"]);
  });

  test("rejects a hostname deeper than the verified zone wildcard", async () => {
    const provider = makeVmPublicationProvider(() => fakeClient({
      verificationCreate: async () => domainVerification({ domain: "example.com" }),
    }));

    const error = await Effect.runPromise(Effect.flip(
      provider.createDomainVerification({
        domain: "example.com",
        hostname: "deep.preview.example.com",
      }),
    ));
    expect(error).toBeInstanceOf(VmPublicationProviderError);
    expect(error.operation).toBe("createDomainVerification");
  });

  test("certificate readiness recognizes exact and one-label wildcard coverage", async () => {
    let certificates: CertificateInfo[] = [
      {
        domain: "app.example.com",
        wildcard: false,
        active: false,
        notAfter: CREATED_AT,
        generation: 0,
      },
      {
        domain: "example.com",
        wildcard: true,
        active: true,
        notAfter: "2026-12-01T00:00:00.000Z",
        generation: 4,
      },
    ];
    let listCalls = 0;
    const client = fakeClient({
      certificateList: async () => {
        listCalls += 1;
        return certificates;
      },
    });
    const provider = makeVmPublicationProvider(() => client);

    await expect(
      Effect.runPromise(provider.getCertificateStatus("app.example.com")),
    ).resolves.toMatchObject({
      state: "active",
      ready: true,
      source: "account",
      certificate: { domain: "example.com", wildcard: true, active: true },
    });
    await expect(
      Effect.runPromise(provider.getCertificateStatus("deep.app.example.com")),
    ).resolves.toMatchObject({ state: "missing", ready: false, certificate: null });

    certificates = [
      {
        domain: "pending.example.com",
        wildcard: false,
        active: false,
        notAfter: CREATED_AT,
        generation: 0,
      },
    ];
    await expect(
      Effect.runPromise(provider.getCertificateStatus("pending.example.com")),
    ).resolves.toMatchObject({ state: "pending", ready: false });

    // The CMUX generated zone is ordinary account inventory: its wildcard
    // certificate must be live before a generated name is ready.
    certificates = [
      {
        domain: "cmux.sh",
        wildcard: true,
        active: true,
        notAfter: "2026-12-01T00:00:00.000Z",
        generation: 1,
      },
    ];
    await expect(
      Effect.runPromise(provider.getCertificateStatus("generated123.cmux.sh")),
    ).resolves.toMatchObject({
      state: "active",
      ready: true,
      source: "account",
      certificate: { domain: "cmux.sh", wildcard: true, active: true },
    });
    certificates = [];
    await expect(
      Effect.runPromise(provider.getCertificateStatus("generated123.cmux.sh")),
    ).resolves.toMatchObject({ state: "missing", ready: false, source: "none" });

    // Only Freestyle's own style.dev zone is covered by the platform certificate.
    await expect(
      Effect.runPromise(provider.getCertificateStatus("free-preview.style.dev")),
    ).resolves.toEqual({
      hostname: "free-preview.style.dev",
      state: "active",
      ready: true,
      source: "platform",
      certificate: null,
    });
    expect(listCalls).toBe(5);
  });
});
