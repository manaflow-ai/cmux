import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import {
  CloudVmPublicationRepository,
  PublicationConflictError,
  PublicationNotFoundError,
  type CloudVmDomainRow,
  type CloudVmPublicationRepositoryShape,
  type CloudVmPublicationRow,
  type CloudVmPublicationTarget,
} from "../services/vm-publications/repository";
import {
  VmPublicationProvider,
  VmPublicationProviderError,
  type PublicationDomainVerification,
  type VmPublicationProviderShape,
} from "../services/vm-publications/provider";
import {
  createPublication,
  deletePublication,
  PublicationConfigurationError,
  updatePublicationAccess,
  verifyPublication,
} from "../services/vm-publications/workflows";
import {
  handlePublicationCreate,
  handlePublicationList,
  type PublicationWorkflowRunner,
} from "../app/api/vm/publications/route";
import {
  publicationErrorResponse,
  publicationForwardAuthConfig,
  publicationGeneratedDomain,
  requestedPublicationTeamId,
  withAuthedPublicationApiRoute,
} from "../app/api/vm/publications/routeShared";

const NOW = new Date("2026-09-02T20:00:00.000Z");

function domain(
  kind: "generated" | "custom",
  overrides: Partial<CloudVmDomainRow> = {},
): CloudVmDomainRow {
  return {
    id: `domain-${kind}`,
    ownerUserId: "owner-1",
    hostname: kind === "generated" ? "generated123.cmux.sh" : "preview.example.com",
    kind,
    provider: "freestyle",
    providerVerificationId: kind === "custom" ? "verification-1" : null,
    verificationState: kind === "custom" ? "pending" : "not_required",
    certificateState: kind === "custom" ? "missing" : "active",
    verificationRecords: [],
    createdAt: NOW,
    updatedAt: NOW,
    ...overrides,
  };
}

function publication(
  accessMode: "personal" | "team" | "public",
  overrides: Partial<CloudVmPublicationRow> = {},
): CloudVmPublicationRow {
  return {
    id: "publication-1",
    ownerUserId: "owner-1",
    vmId: "db-vm-1",
    domainId: "domain-generated",
    hostname: "generated123.cmux.sh",
    hostnameClaimedAt: NOW,
    port: 3_000,
    accessMode,
    teamId: accessMode === "team" ? "team-1" : null,
    providerTlsRuleId: null,
    providerForwardAuthId: accessMode === "public" ? null : "forward-auth-shared",
    routingRevision: 1,
    state: "provisioning",
    createdAt: NOW,
    updatedAt: NOW,
    disabledAt: null,
    ...overrides,
  };
}

function target(
  publicationRow: CloudVmPublicationRow,
  domainRow = domain("generated"),
): CloudVmPublicationTarget {
  return {
    publication: publicationRow,
    domain: domainRow,
    vm: {
      id: "db-vm-1",
      provider: "freestyle",
      providerVmId: "vm-provider-1",
    } as CloudVmPublicationTarget["vm"],
  };
}

function fakeRepository(
  overrides: Partial<CloudVmPublicationRepositoryShape>,
): CloudVmPublicationRepositoryShape {
  return new Proxy(overrides as CloudVmPublicationRepositoryShape, {
    get(object, property, receiver) {
      if (Reflect.has(object, property)) return Reflect.get(object, property, receiver);
      if (property === "claimVmPublicationOperation") {
        return () => Effect.succeed({ kind: "claimed" as const, vmId: "db-vm-1" });
      }
      if (property === "releaseVmPublicationOperation") {
        return () => Effect.succeed(true);
      }
      return () => {
        throw new Error(`unexpected repository call: ${String(property)}`);
      };
    },
  });
}

function fakeProvider(
  overrides: Partial<VmPublicationProviderShape>,
): VmPublicationProviderShape {
  return new Proxy(overrides as VmPublicationProviderShape, {
    get(object, property, receiver) {
      if (Reflect.has(object, property)) return Reflect.get(object, property, receiver);
      return () => {
        throw new Error(`unexpected provider call: ${String(property)}`);
      };
    },
  });
}

async function run<A, E>(
  program: Effect.Effect<A, E, CloudVmPublicationRepository | VmPublicationProvider>,
  repository: CloudVmPublicationRepositoryShape,
  provider: VmPublicationProviderShape,
): Promise<A> {
  return Effect.runPromise(program.pipe(
    Effect.provideService(CloudVmPublicationRepository, repository),
    Effect.provideService(VmPublicationProvider, provider),
  ));
}

const verification: PublicationDomainVerification = {
  verificationId: "verification-1",
  domain: "preview.example.com",
  state: "pending",
  verifiedAt: null,
  createdAt: NOW.toISOString(),
  dnsInstructions: {
    verification: {
      purpose: "verification",
      recordTypes: ["TXT"],
      name: "_freestyle-verification.preview.example.com",
      value: "freestyle-verification=secret",
    },
    routing: {
      purpose: "routing",
      recordTypes: ["ALIAS", "ANAME", "CNAME_FLATTENING"],
      name: "preview.example.com",
      value: "beta-web.freestyle.sh",
    },
    certificate: {
      purpose: "certificate",
      recordTypes: ["NS"],
      name: "_acme-challenge.preview.example.com",
      value: "beta-dns.freestyle.sh",
    },
  },
};

describe("Cloud VM publication workflows", () => {
  test("rejects a non-Freestyle or unowned VM before creating provider verification", async () => {
    let providerCalled = false;
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      reservePublicationWithNewDomain: () => Effect.fail(
        new PublicationNotFoundError({ resource: "vm" }),
      ),
    });
    const provider = fakeProvider({
      createDomainVerification: () => {
        providerCalled = true;
        return Effect.succeed(verification);
      },
    });

    const result = await Effect.runPromise(Effect.either(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "foreign-or-unowned-vm",
      port: 3_000,
      hostname: "preview.example.com",
      accessMode: "public",
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, provider),
    )));

    expect(result._tag).toBe("Left");
    expect(providerCalled).toBeFalse();
  });

  test("mints generated names under the configured zone and keeps that zone reserved", async () => {
    const reserved: string[] = [];
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      reservePublicationWithNewDomain: (input) => {
        reserved.push(input.hostname);
        return Effect.fail(new PublicationNotFoundError({ resource: "vm" }));
      },
    });
    const provider = fakeProvider({});
    const attempt = (overrides: { hostname?: string; generatedDomain?: string }) =>
      Effect.runPromise(Effect.either(createPublication({
        principal: { userId: "owner-1", teamIds: [] },
        providerVmId: "vm-provider-1",
        port: 3_000,
        accessMode: "public",
        now: NOW,
        ...overrides,
      }).pipe(
        Effect.provideService(CloudVmPublicationRepository, repository),
        Effect.provideService(VmPublicationProvider, provider),
      )));

    await attempt({});
    await attempt({ generatedDomain: "Preview.Example.Org." });
    expect(reserved).toHaveLength(2);
    expect(reserved[0]).toMatch(/^[0-9a-f]{20}\.cmux\.sh$/u);
    expect(reserved[1]).toMatch(/^[0-9a-f]{20}\.preview\.example\.org$/u);

    for (const hostname of [
      "cmux.sh",
      "taken.cmux.sh",
      "deep.taken.cmux.sh",
      "free.style.dev",
    ]) {
      const result = await attempt({ hostname });
      expect(result._tag).toBe("Left");
      expect(result._tag === "Left" ? result.left : null).toMatchObject({
        _tag: "PublicationInputError",
        reason: "generated_hostname_reserved",
        field: "hostname",
      });
    }
    expect(reserved).toHaveLength(2);

    // A customer zone that merely contains the generated zone's labels is theirs.
    await attempt({ hostname: "cmux.sh.example.com" });
    expect(reserved).toEqual([reserved[0], reserved[1], "cmux.sh.example.com"]);

    const misconfigured = await attempt({ generatedDomain: "not a zone" });
    expect(misconfigured._tag === "Left" ? misconfigured.left : null).toMatchObject({
      _tag: "PublicationConfigurationError",
      reason: "invalid_generated_domain",
    });
    expect(reserved).toHaveLength(3);
  });

  test("prefers a verified covering zone over a longer pending one and forwards the VM account scope", async () => {
    const verifiedApex = domain("custom", {
      id: "domain-apex",
      hostname: "example.com",
      verificationState: "verified",
      certificateState: "active",
    });
    const pendingExact = domain("custom", {
      id: "domain-exact",
      hostname: "app.example.com",
      verificationState: "pending",
      certificateState: "missing",
    });
    const captured: { current: Record<string, unknown> | null } = { current: null };
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([pendingExact, verifiedApex]),
      reservePublication: (input) => {
        captured.current = input as unknown as Record<string, unknown>;
        return Effect.fail(new PublicationNotFoundError({ resource: "vm" }));
      },
    });

    const result = await Effect.runPromise(Effect.either(createPublication({
      principal: { userId: "owner-1", teamIds: ["team-1"], billingTeamId: "team-1" },
      providerVmId: "vm-provider-1",
      port: 3_000,
      hostname: "app.example.com",
      accessMode: "public",
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, fakeProvider({})),
    )));

    expect(result._tag).toBe("Left");
    expect(captured.current).toMatchObject({
      domainId: "domain-apex",
      hostname: "app.example.com",
      ownerUserId: "owner-1",
      billingTeamId: "team-1",
      teamIds: ["team-1"],
    });
  });

  test("creates a custom reservation with lossless DNS instructions before any TLS rule", async () => {
    const calls: string[] = [];
    const initialDomain = domain("custom", { providerVerificationId: null });
    const verifiedDomain = domain("custom", {
      verificationRecords: Object.values(verification.dnsInstructions),
    });
    const reserved = target(publication("public", {
      domainId: verifiedDomain.id,
      hostname: verifiedDomain.hostname,
      hostnameClaimedAt: null,
    }), verifiedDomain);
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      updateDomainState: () => {
        calls.push("domain.verification.persist");
        return Effect.succeed(verifiedDomain);
      },
      reservePublicationWithNewDomain: () => {
        calls.push("publication.reserve-zone");
        return Effect.succeed({ ...reserved, domain: initialDomain });
      },
    });
    const provider = fakeProvider({
      createDomainVerification: () => {
        calls.push("provider.verification.create");
        return Effect.succeed(verification);
      },
    });

    const result = await run(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      hostname: "preview.example.com",
      accessMode: "public",
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "publication.reserve-zone",
      "provider.verification.create",
      "domain.verification.persist",
    ]);
    expect(result.state).toBe("provisioning");
    expect(result.verification?.dnsInstructions.routing.recordTypes).toEqual([
      "ALIAS",
      "ANAME",
      "CNAME_FLATTENING",
    ]);
  });

  test("reuses a verified owner zone for a one-label publication hostname", async () => {
    const calls: string[] = [];
    const zoneVerification: PublicationDomainVerification = {
      ...verification,
      verificationId: "verification-zone",
      domain: "example.com",
      state: "verified",
      verifiedAt: NOW.toISOString(),
      dnsInstructions: {
        verification: {
          ...verification.dnsInstructions.verification,
          name: "_freestyle-verification.example.com",
        },
        routing: {
          ...verification.dnsInstructions.routing,
          name: "example.com",
        },
        certificate: {
          ...verification.dnsInstructions.certificate,
          name: "_acme-challenge.example.com",
        },
      },
    };
    const verifiedZone = domain("custom", {
      id: "domain-example",
      hostname: "example.com",
      providerVerificationId: zoneVerification.verificationId,
      verificationState: "verified",
      certificateState: "active",
      verificationRecords: Object.values(zoneVerification.dnsInstructions),
    });
    const reservedPublication = publication("public", {
      domainId: verifiedZone.id,
      hostname: "app.example.com",
      hostnameClaimedAt: NOW,
      providerForwardAuthId: null,
    });
    const reserved = target(reservedPublication, verifiedZone);
    const withRule = {
      ...reservedPublication,
      providerTlsRuleId: "tls-rule-app",
    };
    const active = { ...withRule, state: "active" as const };
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([verifiedZone]),
      reservePublication: (input) => {
        calls.push("publication.reserve-existing-zone");
        expect(input.domainId).toBe(verifiedZone.id);
        expect(input.hostname).toBe("app.example.com");
        return Effect.succeed(reserved);
      },
      updateDomainState: (input) => {
        calls.push("wildcard.persist");
        expect(input.id).toBe(verifiedZone.id);
        expect(input.certificateState).toBe("active");
        return Effect.succeed(verifiedZone);
      },
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => Effect.sync(() => {
        calls.push("operation.release");
        return true;
      }),
      recordProvisioningTlsRule: () => {
        calls.push("rule.persist");
        return Effect.succeed(withRule);
      },
      activatePublication: () => {
        calls.push("publication.activate");
        return Effect.succeed(active);
      },
    });
    const provider = fakeProvider({
      requestWildcardCertificate: (hostname) => {
        calls.push("wildcard.request");
        expect(hostname).toBe("example.com");
        return Effect.succeed({} as never);
      },
      getWildcardCertificateStatus: (hostname) => {
        calls.push("wildcard.observe");
        expect(hostname).toBe("example.com");
        return Effect.succeed({ state: "active", ready: true } as never);
      },
      reconcileTlsRule: (_id, spec) => {
        calls.push("rule.reconcile");
        expect(spec.hostname).toBe("app.example.com");
        return Effect.succeed({
          disposition: "created" as const,
          rule: { tlsRuleId: "tls-rule-app" } as never,
        });
      },
      getCertificateStatus: (hostname) => {
        calls.push("certificate.observe");
        expect(hostname).toBe("app.example.com");
        return Effect.succeed({ state: "active", ready: true } as never);
      },
    });

    const result = await run(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      hostname: "app.example.com",
      accessMode: "public",
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "publication.reserve-existing-zone",
      "operation.claim",
      "wildcard.request",
      "wildcard.observe",
      "wildcard.persist",
      "rule.reconcile",
      "rule.persist",
      "certificate.observe",
      "publication.activate",
      "operation.release",
    ]);
    expect(result).toMatchObject({
      hostname: "app.example.com",
      url: "https://app.example.com",
      state: "active",
      verification: {
        verificationId: "verification-zone",
        domain: "example.com",
        dnsInstructions: {
          routing: {
            purpose: "routing",
            recordTypes: ["CNAME"],
            name: "app.example.com",
            value: "beta-web.freestyle.sh",
          },
          certificate: {
            purpose: "certificate",
            recordTypes: ["NS"],
            name: "_acme-challenge.example.com",
            value: "beta-dns.freestyle.sh",
          },
        },
      },
    });
  });

  test("starts a new exact zone when an owned zone cannot cover a deeper hostname", async () => {
    const parentZone = domain("custom", {
      id: "domain-example",
      hostname: "example.com",
      verificationState: "verified",
      certificateState: "active",
    });
    const requestedHostname = "deep.app.example.com";
    const initialDomain = domain("custom", {
      id: "domain-deep-app",
      hostname: requestedHostname,
      providerVerificationId: null,
    });
    const deepVerification: PublicationDomainVerification = {
      ...verification,
      verificationId: "verification-deep-app",
      domain: requestedHostname,
      dnsInstructions: {
        verification: {
          ...verification.dnsInstructions.verification,
          name: `_freestyle-verification.${requestedHostname}`,
        },
        routing: {
          ...verification.dnsInstructions.routing,
          name: requestedHostname,
        },
        certificate: {
          ...verification.dnsInstructions.certificate,
          name: `_acme-challenge.${requestedHostname}`,
        },
      },
    };
    const persistedDomain = {
      ...initialDomain,
      providerVerificationId: deepVerification.verificationId,
      verificationRecords: Object.values(deepVerification.dnsInstructions),
    };
    const reserved = target(publication("public", {
      domainId: initialDomain.id,
      hostname: requestedHostname,
      hostnameClaimedAt: null,
    }), initialDomain);
    let reusedParent = false;
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([parentZone]),
      reservePublication: () => {
        reusedParent = true;
        return Effect.succeed({} as never);
      },
      reservePublicationWithNewDomain: (input) => {
        expect(input.domainHostname).toBe(requestedHostname);
        expect(input.hostname).toBe(requestedHostname);
        return Effect.succeed(reserved);
      },
      updateDomainState: () => Effect.succeed(persistedDomain),
    });
    const provider = fakeProvider({
      createDomainVerification: (input) => {
        expect(input).toEqual({
          domain: requestedHostname,
          hostname: requestedHostname,
        });
        return Effect.succeed(deepVerification);
      },
    });

    const result = await run(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      hostname: requestedHostname,
      accessMode: "public",
      now: NOW,
    }), repository, provider);

    expect(reusedParent).toBeFalse();
    expect(result.verification).toMatchObject({
      domain: requestedHostname,
      dnsInstructions: {
        routing: { name: requestedHostname },
        certificate: { name: `_acme-challenge.${requestedHostname}` },
      },
    });
  });

  test("records a generated rule before certificate observation and activation", async () => {
    const calls: string[] = [];
    const generatedDomain = domain("generated");
    const reserved = target(publication("personal", {
      providerForwardAuthId: null,
    }), generatedDomain);
    const withRule = publication("personal", {
      providerTlsRuleId: "tls-rule-1",
      providerForwardAuthId: "forward-auth-shared",
    });
    const active = { ...withRule, state: "active" as const };
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      reservePublicationWithNewDomain: () => Effect.succeed(reserved),
      claimProviderForwardAuth: () => {
        calls.push("forward-auth.claim");
        return Effect.succeed({
          kind: "ready" as const,
          config: { providerForwardAuthId: "forward-auth-old" } as never,
        });
      },
      replaceProviderForwardAuth: () => {
        calls.push("forward-auth.replace");
        return Effect.succeed({ providerForwardAuthId: "forward-auth-shared" } as never);
      },
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => {
        return Effect.sync(() => {
          calls.push("operation.release");
          return true;
        });
      },
      recordProvisioningTlsRule: () => {
        calls.push("rule.persist");
        return Effect.succeed(withRule);
      },
      updateDomainState: () => {
        calls.push("certificate.persist");
        return Effect.succeed(generatedDomain);
      },
      activatePublication: () => {
        calls.push("publication.activate");
        return Effect.succeed(active);
      },
    });
    const provider = fakeProvider({
      ensureSharedForwardAuth: () => {
        calls.push("forward-auth.ensure");
        return Effect.succeed({
          forwardAuthId: "forward-auth-shared",
          disposition: "updated" as const,
        });
      },
      reconcileTlsRule: () => {
        calls.push("rule.reconcile");
        return Effect.succeed({
          disposition: "created" as const,
          rule: { tlsRuleId: "tls-rule-1" } as never,
        });
      },
      getCertificateStatus: () => {
        calls.push("certificate.observe");
        return Effect.succeed({ state: "active", ready: true } as never);
      },
    });

    const result = await run(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      accessMode: "personal",
      generatedHostname: generatedDomain.hostname,
      forwardAuth: {
        url: "https://cmux.com/api/freestyle/forward-auth",
        serviceToken: "a-secret-long-enough-for-the-provider",
      },
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "operation.claim",
      "forward-auth.claim",
      "forward-auth.ensure",
      "forward-auth.replace",
      "rule.reconcile",
      "rule.persist",
      "certificate.observe",
      "certificate.persist",
      "publication.activate",
      "operation.release",
    ]);
    expect(result.state).toBe("active");
  });

  test("does not touch TLS while another VM publication operation holds the lease", async () => {
    let providerCalled = false;
    let released = false;
    const generatedDomain = domain("generated");
    const reserved = target(publication("public"), generatedDomain);
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      reservePublicationWithNewDomain: () => Effect.succeed(reserved),
      claimVmPublicationOperation: () => Effect.succeed({
        kind: "in_progress",
        retryAt: new Date(NOW.getTime() + 30_000),
      }),
      releaseVmPublicationOperation: () => Effect.sync(() => {
        released = true;
        return true;
      }),
    });
    const provider = fakeProvider({
      reconcileTlsRule: () => {
        providerCalled = true;
        return Effect.succeed({} as never);
      },
    });

    const result = await Effect.runPromise(Effect.either(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      accessMode: "public",
      generatedHostname: generatedDomain.hostname,
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, provider),
    )));

    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({ _tag: "PublicationProvisioningBusyError" });
    }
    expect(providerCalled).toBeFalse();
    expect(released).toBeFalse();
  });

  test("releases the VM operation lease after a TLS provider failure", async () => {
    let released = false;
    const generatedDomain = domain("generated");
    const reserved = target(publication("public"), generatedDomain);
    const repository = fakeRepository({
      listOwnedDomains: () => Effect.succeed([]),
      reservePublicationWithNewDomain: () => Effect.succeed(reserved),
      claimVmPublicationOperation: () => Effect.succeed({
        kind: "claimed",
        vmId: "db-vm-1",
      }),
      releaseVmPublicationOperation: () => Effect.sync(() => {
        released = true;
        return true;
      }),
    });
    const provider = fakeProvider({
      reconcileTlsRule: () => Effect.fail(new VmPublicationProviderError({
        operation: "reconcileTlsRule",
        cause: new Error("provider unavailable"),
      })),
    });

    const result = await Effect.runPromise(Effect.either(createPublication({
      principal: { userId: "owner-1", teamIds: [] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      accessMode: "public",
      generatedHostname: generatedDomain.hostname,
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, provider),
    )));

    expect(result._tag).toBe("Left");
    expect(released).toBeTrue();
  });

  test("verifies ownership, persists the rule, and waits for a custom certificate", async () => {
    const calls: string[] = [];
    const pendingDomain = domain("custom", {
      verificationRecords: Object.values(verification.dnsInstructions),
    });
    const verifiedDomain = {
      ...pendingDomain,
      verificationState: "verified" as const,
      certificateState: "pending" as const,
    };
    const current = publication("public", {
      domainId: pendingDomain.id,
      hostname: pendingDomain.hostname,
      hostnameClaimedAt: null,
      providerForwardAuthId: null,
    });
    const withRule = {
      ...current,
      providerTlsRuleId: "tls-rule-custom",
    };
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current, pendingDomain)),
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => {
        return Effect.sync(() => {
          calls.push("operation.release");
          return true;
        });
      },
      updateDomainState: (input) => {
        if (input.providerVerificationId) {
          calls.push("verification.refresh.persist");
          return Effect.succeed(pendingDomain);
        } else if (input.verificationState === "verified") {
          calls.push("ownership.persist");
        } else {
          calls.push("certificate.persist");
        }
        return Effect.succeed(verifiedDomain);
      },
      recordProvisioningTlsRule: () => {
        calls.push("rule.persist");
        return Effect.succeed(withRule);
      },
    });
    const provider = fakeProvider({
      getDomainVerification: () => {
        calls.push("ownership.read");
        return Effect.succeed(verification);
      },
      completeDomainVerification: () => {
        calls.push("ownership.complete");
        return Effect.succeed({
          domain: "preview.example.com",
          createdAt: NOW.toISOString(),
          verificationId: "verification-1",
        });
      },
      requestWildcardCertificate: () => {
        calls.push("wildcard.request");
        return Effect.succeed({} as never);
      },
      getWildcardCertificateStatus: () => {
        calls.push("wildcard.observe");
        return Effect.succeed({ state: "pending", ready: false } as never);
      },
      reconcileTlsRule: () => {
        calls.push("rule.reconcile");
        return Effect.succeed({
          disposition: "created" as const,
          rule: { tlsRuleId: "tls-rule-custom" } as never,
        });
      },
      getCertificateStatus: () => {
        calls.push("certificate.observe");
        return Effect.succeed({ state: "pending", ready: false } as never);
      },
    });

    const result = await run(verifyPublication({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "ownership.read",
      "verification.refresh.persist",
      "ownership.complete",
      "ownership.persist",
      "operation.claim",
      "wildcard.request",
      "wildcard.observe",
      "certificate.persist",
      "rule.reconcile",
      "rule.persist",
      "certificate.observe",
      "operation.release",
    ]);
    expect(result.state).toBe("provisioning");
    expect(result.verification?.state).toBe("verified");
  });

  test("does not trust a mismatched completed domain verification", async () => {
    let markedVerified = false;
    const pendingDomain = domain("custom", {
      verificationRecords: Object.values(verification.dnsInstructions),
    });
    const current = publication("public", {
      domainId: pendingDomain.id,
      hostname: pendingDomain.hostname,
      hostnameClaimedAt: null,
      providerForwardAuthId: null,
    });
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current, pendingDomain)),
      updateDomainState: (input) => {
        if (input.verificationState === "verified") markedVerified = true;
        return Effect.succeed(pendingDomain);
      },
    });
    const provider = fakeProvider({
      getDomainVerification: () => Effect.succeed(verification),
      completeDomainVerification: () => Effect.succeed({
        domain: "other.example.com",
        createdAt: NOW.toISOString(),
        verificationId: "verification-other",
      }),
    });

    const result = await Effect.runPromise(Effect.either(verifyPublication({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, provider),
    )));

    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "PublicationInvariantError",
        reason: "provider_verification_mismatch",
      });
    }
    expect(markedVerified).toBeFalse();
  });

  test("recovers a provider-completed verification without completing it twice", async () => {
    let completedAgain = false;
    const pendingDomain = domain("custom", {
      verificationRecords: Object.values(verification.dnsInstructions),
    });
    const verifiedDomain = {
      ...pendingDomain,
      verificationState: "verified" as const,
      certificateState: "pending" as const,
    };
    const current = publication("public", {
      domainId: pendingDomain.id,
      hostname: pendingDomain.hostname,
      hostnameClaimedAt: null,
      providerForwardAuthId: null,
    });
    const withRule = { ...current, providerTlsRuleId: "tls-rule-custom" };
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current, pendingDomain)),
      updateDomainState: () => Effect.succeed(verifiedDomain),
      recordProvisioningTlsRule: () => Effect.succeed(withRule),
    });
    const provider = fakeProvider({
      getDomainVerification: () => Effect.succeed({
        ...verification,
        state: "verified",
        verifiedAt: NOW.toISOString(),
      }),
      completeDomainVerification: () => {
        completedAgain = true;
        return Effect.succeed({} as never);
      },
      requestWildcardCertificate: () => Effect.succeed({} as never),
      getWildcardCertificateStatus: () => Effect.succeed({
        state: "pending",
        ready: false,
      } as never),
      reconcileTlsRule: () => Effect.succeed({
        disposition: "created",
        rule: { tlsRuleId: "tls-rule-custom" } as never,
      }),
      getCertificateStatus: () => Effect.succeed({
        state: "pending",
        ready: false,
      } as never),
    });

    const result = await run(verifyPublication({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      now: NOW,
    }), repository, provider);

    expect(result.verification?.state).toBe("verified");
    expect(completedAgain).toBeFalse();
  });

  test("attaches auth before committing public to protected", async () => {
    const calls: string[] = [];
    const current = publication("public", {
      state: "active",
      providerTlsRuleId: "tls-rule-1",
    });
    const updated = publication("personal", {
      state: "active",
      providerTlsRuleId: "tls-rule-1",
      providerForwardAuthId: "forward-auth-shared",
      routingRevision: 2,
    });
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current)),
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => {
        return Effect.sync(() => {
          calls.push("operation.release");
          return true;
        });
      },
      claimProviderForwardAuth: () => {
        calls.push("forward-auth.claim");
        return Effect.succeed({
          kind: "ready" as const,
          config: { providerForwardAuthId: "forward-auth-shared" } as never,
        });
      },
      commitAccessPolicy: () => {
        calls.push("policy.commit");
        return Effect.succeed(updated);
      },
      revokePublicationSessions: () => {
        calls.push("sessions.revoke");
        return Effect.succeed(0);
      },
    });
    const provider = fakeProvider({
      ensureSharedForwardAuth: () => {
        calls.push("forward-auth.ensure");
        return Effect.succeed({
          forwardAuthId: "forward-auth-shared",
          disposition: "updated" as const,
        });
      },
      updateTlsRule: () => {
        calls.push("rule.protect");
        return Effect.succeed({} as never);
      },
    });

    await run(updatePublicationAccess({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      accessMode: "personal",
      forwardAuth: {
        url: "https://cmux.com/api/freestyle/forward-auth",
        serviceToken: "secret",
      },
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "operation.claim",
      "forward-auth.claim",
      "forward-auth.ensure",
      "rule.protect",
      "policy.commit",
      "sessions.revoke",
      "operation.release",
    ]);
  });

  test("rejects team publication for a team outside current Stack membership", async () => {
    const repository = fakeRepository({});
    const provider = fakeProvider({});
    const result = await Effect.runPromise(Effect.either(createPublication({
      principal: { userId: "owner-1", teamIds: ["team-current"] },
      providerVmId: "vm-provider-1",
      port: 3_000,
      accessMode: "team",
      teamId: "team-other",
      now: NOW,
    }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(VmPublicationProvider, provider),
    )));
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "PublicationInputError",
        reason: "team_not_allowed",
      });
    }
  });

  test("commits public and revokes sessions before detaching auth", async () => {
    const calls: string[] = [];
    const current = publication("personal", {
      state: "active",
      providerTlsRuleId: "tls-rule-1",
    });
    const committed = publication("public", {
      state: "active",
      providerTlsRuleId: "tls-rule-1",
      providerForwardAuthId: "forward-auth-shared",
      routingRevision: 2,
    });
    const detached = { ...committed, providerForwardAuthId: null };
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current)),
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => {
        return Effect.sync(() => {
          calls.push("operation.release");
          return true;
        });
      },
      commitAccessPolicy: () => {
        calls.push("policy.commit");
        return Effect.succeed(committed);
      },
      revokePublicationSessions: () => {
        calls.push("sessions.revoke");
        return Effect.succeed(1);
      },
      recordAppliedForwardAuth: () => {
        calls.push("provider-state.persist");
        return Effect.succeed(detached);
      },
    });
    const provider = fakeProvider({
      updateTlsRule: () => {
        calls.push("rule.detach");
        return Effect.succeed({} as never);
      },
    });

    await run(updatePublicationAccess({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      accessMode: "public",
      now: NOW,
    }), repository, provider);

    expect(calls).toEqual([
      "operation.claim",
      "policy.commit",
      "sessions.revoke",
      "rule.detach",
      "provider-state.persist",
      "operation.release",
    ]);
  });

  test("invalidates routing and sessions before sweeping crash-orphaned hostname rules", async () => {
    const calls: string[] = [];
    const current = publication("personal", {
      state: "provisioning",
      providerTlsRuleId: null,
    });
    const disabling = { ...current, state: "disabling" as const, routingRevision: 2 };
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(current)),
      claimVmPublicationOperation: () => {
        calls.push("operation.claim");
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => {
        return Effect.sync(() => {
          calls.push("operation.release");
          return true;
        });
      },
      beginDisablePublication: () => {
        calls.push("publication.disable");
        return Effect.succeed(disabling);
      },
      revokePublicationSessions: () => {
        calls.push("sessions.revoke");
        return Effect.succeed(1);
      },
      finishDisablePublication: () => {
        calls.push("publication.finish");
        return Effect.succeed({ ...disabling, state: "disabled", disabledAt: NOW });
      },
    });
    const provider = fakeProvider({
      deleteTlsRulesForHostname: () => {
        calls.push("rules.sweep");
        return Effect.succeed(2);
      },
    });

    const result = await run(deletePublication({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: current.id,
      now: NOW,
    }), repository, provider);

    expect(result).toEqual({ deleted: true, id: current.id });
    expect(calls).toEqual([
      "operation.claim",
      "publication.disable",
      "sessions.revoke",
      "rules.sweep",
      "publication.finish",
      "operation.release",
    ]);
  });

  test("resumes a delete left in disabling by a failed sweep", async () => {
    const calls: string[] = [];
    const stuck = publication("public", {
      state: "disabling",
      routingRevision: 2,
      providerTlsRuleId: "tls-rule-1",
      providerForwardAuthId: null,
    });
    const repository = fakeRepository({
      findOwnedPublication: () => Effect.succeed(target(stuck)),
      claimVmPublicationOperation: (input) => {
        calls.push(`operation.claim:${input.intent}`);
        return Effect.succeed({ kind: "claimed", vmId: "db-vm-1" });
      },
      releaseVmPublicationOperation: () => Effect.sync(() => {
        calls.push("operation.release");
        return true;
      }),
      beginDisablePublication: () => {
        calls.push("publication.disable");
        return Effect.succeed(stuck);
      },
      revokePublicationSessions: () => {
        calls.push("sessions.revoke");
        return Effect.succeed(0);
      },
      finishDisablePublication: () => {
        calls.push("publication.finish");
        return Effect.succeed({ ...stuck, state: "disabled", disabledAt: NOW });
      },
    });
    const provider = fakeProvider({
      deleteTlsRulesForHostname: () => {
        calls.push("rules.sweep");
        return Effect.succeed(1);
      },
    });

    const result = await run(deletePublication({
      principal: { userId: "owner-1", teamIds: [] },
      publicationId: stuck.id,
      now: NOW,
    }), repository, provider);

    expect(result).toEqual({ deleted: true, id: stuck.id });
    expect(calls).toEqual([
      "operation.claim:disable",
      "publication.disable",
      "sessions.revoke",
      "rules.sweep",
      "publication.finish",
      "operation.release",
    ]);
  });
});

describe("Cloud VM publication REST adapters", () => {
  test("derives the forward-auth target only from the configured origin", () => {
    const secret = "a-secret-long-enough-for-the-provider";
    expect(publicationForwardAuthConfig({})).toBeUndefined();
    expect(publicationForwardAuthConfig({
      CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET: secret,
      CMUX_VM_PUBLICATION_AUTH_ORIGIN: " https://cmux.com/ ",
    })).toEqual({ url: "https://cmux.com/api/freestyle/forward-auth", serviceToken: secret });
    for (const origin of [
      undefined,
      "",
      "http://cmux.com",
      "https://cmux.com/base",
      "https://user:pw@cmux.com",
      "https://cmux.com/?next=1",
      "not a url",
    ]) {
      expect(publicationForwardAuthConfig({
        CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET: secret,
        CMUX_VM_PUBLICATION_AUTH_ORIGIN: origin,
      })).toEqual({ url: "", serviceToken: secret });
    }
  });

  test("resolves the requested team before authenticating a publication mutation", async () => {
    const verified: unknown[] = [];
    const verify: Parameters<typeof withAuthedPublicationApiRoute>[3] = async (_request, options) => {
      verified.push(options);
      return null;
    };
    const post = new Request("https://cmux.com/api/vm/publications", {
      method: "POST",
      body: JSON.stringify({ vmId: "vm-1", port: 3_000, accessMode: "team", teamId: " team-2 " }),
    });
    const response = await withAuthedPublicationApiRoute(
      post,
      async () => new Response(null),
      async () => {
        throw new Error("unreachable");
      },
      verify,
    );
    expect(response.status).toBe(401);
    expect(verified).toEqual([{ listAllTeams: true, requestedTeamId: "team-2" }]);

    expect(await requestedPublicationTeamId(
      new Request("https://cmux.com/api/vm/publications", { method: "GET" }),
    )).toBeNull();
    expect(await requestedPublicationTeamId(
      new Request("https://cmux.com/api/vm/publications", { method: "POST", body: "not json" }),
    )).toBeNull();
    expect(await requestedPublicationTeamId(
      new Request("https://cmux.com/api/vm/publications/p1", {
        method: "PATCH",
        body: JSON.stringify({ teamId: 42 }),
      }),
    )).toBeNull();
  });

  test("keeps operator configuration names out of client-facing errors", async () => {
    for (const reason of [
      "forward_auth_not_configured",
      "invalid_auth_origin",
      "invalid_generated_domain",
    ] as const) {
      const response = publicationErrorResponse(new PublicationConfigurationError({ reason }));
      expect(response.status).toBe(503);
      const body = await response.json() as {
        readonly message: string;
        readonly action: string;
        readonly reason: string;
      };
      expect(body.reason).toBe(reason);
      expect(`${body.message} ${body.action}`).not.toMatch(/CMUX_VM_PUBLICATION/u);
    }
  });

  test("keeps list and mutation response envelopes stable", async () => {
    const dto = {
      id: "publication-1",
      hostname: "generated123.cmux.sh",
      url: "https://generated123.cmux.sh",
      domainKind: "generated" as const,
      vmId: "vm-provider-1",
      port: 3_000,
      accessMode: "public" as const,
      teamId: null,
      state: "active" as const,
      routingRevision: 1,
      verification: null,
    };
    const listRunner: PublicationWorkflowRunner = async <A>() => [dto] as A;
    const listResponse = await handlePublicationList({
      principal: { userId: "owner-1", teamIds: [] },
      run: listRunner,
    });
    expect(await listResponse.json()).toEqual({ publications: [dto] });

    const createRunner: PublicationWorkflowRunner = async <A>() => dto as A;
    const createResponse = await handlePublicationCreate(
      new Request("https://cmux.com/api/vm/publications", {
        method: "POST",
        body: JSON.stringify({ vmId: "vm-provider-1", port: 3_000, accessMode: "public" }),
      }),
      {
        principal: { userId: "owner-1", teamIds: [] },
        run: createRunner,
      },
      { NODE_ENV: "test" },
    );
    expect(createResponse.status).toBe(201);
    expect(await createResponse.json()).toEqual({ publication: dto });
  });

  test("mints generated names under cmux.sh unless the deployment overrides the zone", () => {
    expect(publicationGeneratedDomain({})).toBe("cmux.sh");
    expect(publicationGeneratedDomain({ CMUX_VM_PUBLICATION_GENERATED_DOMAIN: "   " }))
      .toBe("cmux.sh");
    expect(publicationGeneratedDomain({
      CMUX_VM_PUBLICATION_GENERATED_DOMAIN: " preview.cmux.dev ",
    })).toBe("preview.cmux.dev");
  });

  test("rejects a publish request without a machine before invoking a workflow", async () => {
    let invoked = false;
    const runner: PublicationWorkflowRunner = async <A>() => {
      invoked = true;
      return {} as A;
    };
    const response = await handlePublicationCreate(
      new Request("https://cmux.com/api/vm/publications", {
        method: "POST",
        body: JSON.stringify({ port: 3_000, accessMode: "public" }),
      }),
      {
        principal: { userId: "owner-1", teamIds: [] },
        run: runner,
      },
      { NODE_ENV: "test" },
    );
    expect(response.status).toBe(400);
    expect(invoked).toBeFalse();
  });

  test("returns actionable conflicts when VM teardown freezes publication work", async () => {
    const response = publicationErrorResponse(new PublicationConflictError({
      reason: "vm_publication_frozen",
    }));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "vm_publication_conflict",
      message: "That Cloud VM is already being removed.",
      action: "Choose another running Cloud VM for this domain.",
      reason: "vm_publication_frozen",
    });
  });
});
