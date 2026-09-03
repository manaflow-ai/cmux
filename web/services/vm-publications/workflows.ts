import { randomUUID } from "node:crypto";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import type { CloudVmDomainVerificationRecord } from "../../db/schema";
import type { ProviderId } from "../vms/drivers";
import {
  CloudVmPublicationRepository,
  CloudVmPublicationRepositoryLive,
  PublicationConflictError,
  PublicationNotFoundError,
  type CloudVmDomainRow,
  type CloudVmPublicationAccessMode,
  type CloudVmPublicationRepositoryShape,
  type CloudVmPublicationRow,
  type CloudVmPublicationTarget,
} from "./repository";
import {
  VmPublicationProvider,
  VmPublicationProviderLive,
  isFreestylePlatformHostname,
  publicationRoutingDnsInstruction,
  type PublicationDnsInstruction,
  type PublicationDomainVerification,
  type VmPublicationProviderShape,
} from "./provider";
import { friendlyPublicationLabel } from "./friendlyNames";
import { normalizePublicationHostname } from "./security";

const FORWARD_AUTH_LEASE_MS = 30_000;
// Publication routes have a 120-second execution budget. Keep the durable VM
// guard alive slightly beyond it so a timed-out request cannot overlap delete.
const VM_PUBLICATION_OPERATION_LEASE_MS = 150_000;

export type PublicationPrincipal = {
  readonly userId: string;
  readonly teamIds: readonly string[];
  /** The account scope VM lookups follow (selected team or `X-Cmux-Team-Id`). */
  readonly billingTeamId?: string | null;
};

export type PublicationForwardAuthConfig = {
  readonly url: string;
  readonly serviceToken: string;
};

/**
 * The CMUX-owned zone generated publication hostnames are minted under. The
 * operator verifies it once in the CMUX Freestyle account and keeps its
 * wildcard DNS and certificate live; `CMUX_VM_PUBLICATION_GENERATED_DOMAIN`
 * overrides it per deployment.
 */
export const DEFAULT_GENERATED_PUBLICATION_DOMAIN = "cmux.sh";

export type PublicationVerificationDto = {
  readonly verificationId: string;
  readonly domain: string;
  readonly state: CloudVmDomainRow["verificationState"];
  readonly dnsInstructions: {
    readonly verification: CloudVmDomainVerificationRecord;
    readonly routing: CloudVmDomainVerificationRecord;
    readonly certificate: CloudVmDomainVerificationRecord;
  };
};

/** One custom zone an account owns, listed apart from the publications routed through it. */
export type CustomDomainDto = {
  readonly id: string;
  readonly hostname: string;
  readonly verificationState: CloudVmDomainRow["verificationState"];
  readonly certificateState: CloudVmDomainRow["certificateState"];
  readonly createdAt: string;
  /** Zone-level proof and certificate delegation; per-hostname routing records live on publications. */
  readonly dnsInstructions: {
    readonly verification: CloudVmDomainVerificationRecord;
    readonly certificate: CloudVmDomainVerificationRecord;
  } | null;
  readonly publications: readonly {
    readonly id: string;
    readonly hostname: string;
    readonly state: CloudVmPublicationRow["state"];
  }[];
};

export type PublicationDto = {
  readonly id: string;
  readonly hostname: string;
  readonly url: string;
  readonly domainKind: CloudVmDomainRow["kind"];
  readonly vmId: string;
  readonly port: number;
  readonly accessMode: CloudVmPublicationAccessMode;
  readonly teamId: string | null;
  readonly state: CloudVmPublicationRow["state"];
  readonly routingRevision: number;
  readonly verification: PublicationVerificationDto | null;
};

export type PublicationInvalidReason =
  | "invalid_hostname"
  | "invalid_port"
  | "invalid_access_mode"
  | "team_required"
  | "team_not_allowed"
  | "generated_hostname_reserved";

export class PublicationInputError extends Data.TaggedError(
  "PublicationInputError",
)<{
  readonly reason: PublicationInvalidReason;
  readonly field: "hostname" | "port" | "accessMode" | "teamId";
}> {}

export class PublicationConfigurationError extends Data.TaggedError(
  "PublicationConfigurationError",
)<{
  readonly reason:
    | "forward_auth_not_configured"
    | "invalid_auth_origin"
    | "invalid_generated_domain";
}> {}

export class PublicationProvisioningBusyError extends Data.TaggedError(
  "PublicationProvisioningBusyError",
)<{
  readonly retryAt: Date;
}> {}

export class PublicationInvariantError extends Data.TaggedError(
  "PublicationInvariantError",
)<{
  readonly reason:
    | "provider_vm_id_missing"
    | "provider_tls_rule_id_missing"
    | "provider_verification_id_missing"
    | "provider_verification_mismatch";
}> {}

export const VmPublicationWorkflowLive = Layer.mergeAll(
  CloudVmPublicationRepositoryLive,
  VmPublicationProviderLive,
);

/** Run an Effect workflow while preserving its typed domain failure for REST mapping. */
export async function runVmPublicationWorkflow<A, E>(
  program: Effect.Effect<
    A,
    E,
    CloudVmPublicationRepository | VmPublicationProvider
  >,
): Promise<A> {
  const result = await Effect.runPromise(
    Effect.either(program.pipe(Effect.provide(VmPublicationWorkflowLive))),
  );
  if (result._tag === "Left") throw result.left;
  return result.right;
}

export function listPublications(input: {
  readonly principal: PublicationPrincipal;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const targets = yield* repository.listOwnedPublications(input.principal.userId);
    return targets.map(publicationDto);
  });
}

export function listCustomDomains(input: {
  readonly principal: PublicationPrincipal;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const domains = yield* repository.listOwnedDomains(input.principal.userId);
    const targets = yield* repository.listOwnedPublications(input.principal.userId);
    return domains
      .filter((domain) => domain.kind === "custom")
      .map((domain): CustomDomainDto => {
        const verification = domain.verificationRecords.find(
          (record) => record.purpose === "verification",
        );
        const certificate = domain.verificationRecords.find(
          (record) => record.purpose === "certificate",
        );
        return {
          id: domain.id,
          hostname: domain.hostname,
          verificationState: domain.verificationState,
          certificateState: domain.certificateState,
          createdAt: domain.createdAt.toISOString(),
          dnsInstructions: verification && certificate
            ? { verification, certificate }
            : null,
          publications: targets
            .filter((target) =>
              target.domain.id === domain.id && target.publication.state !== "disabled"
            )
            .map((target) => ({
              id: target.publication.id,
              hostname: target.publication.hostname,
              state: target.publication.state,
            })),
        };
      });
  });
}

export function createPublication(input: {
  readonly principal: PublicationPrincipal;
  readonly providerVmId: string;
  readonly port: number;
  readonly hostname?: string;
  readonly accessMode: CloudVmPublicationAccessMode;
  readonly teamId?: string | null;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly now?: Date;
  /** Zone for generated names; defaults to `DEFAULT_GENERATED_PUBLICATION_DOMAIN`. */
  readonly generatedDomain?: string;
  /** Deterministic seam for focused tests; production callers leave this unset. */
  readonly generatedHostname?: string;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const now = input.now ?? new Date();
    const access = yield* validateAccessPolicy(
      input.accessMode,
      input.teamId,
      input.principal.teamIds,
    );
    if (!Number.isInteger(input.port) || input.port < 1 || input.port > 65_535) {
      return yield* new PublicationInputError({ reason: "invalid_port", field: "port" });
    }

    // Publication ingress is a Freestyle TLS capability. Keeping this literal
    // prevents a future default VM provider from sending foreign VM ids to the
    // Freestyle account-wide control plane.
    const providerId: ProviderId = "freestyle";
    const generatedDomain = yield* normalizedGeneratedPublicationDomain(
      input.generatedDomain,
    );
    const isCustom = input.hostname !== undefined;
    let target = yield* reservePublicationTarget({
      repository,
      principal: input.principal,
      providerId,
      providerVmId: input.providerVmId,
      port: input.port,
      access,
      hostname: input.hostname,
      generatedHostname: input.generatedHostname,
      generatedDomain,
      now,
    });
    let domain = target.domain;

    // Customer DNS must be installed before CMUX creates the ingress rule.
    // Reserve the owned/running Freestyle VM first, so an invalid VM id can
    // never leave an external verification orphan. The verify operation can
    // resume this durable provisioning record after any provider failure.
    if (isCustom) {
      if (domain.verificationState !== "verified") {
        domain = yield* ensureCustomDomainVerification({
          repository,
          provider,
          domain,
          publicationHostname: target.publication.hostname,
          ownerUserId: input.principal.userId,
          now,
        });
        target = { ...target, domain };
      }
      if (domain.verificationState !== "verified") return publicationDto(target);
    }

    target = yield* provisionReservedPublication({
      repository,
      provider,
      target,
      ownerUserId: input.principal.userId,
      forwardAuth: input.forwardAuth,
      now,
    });
    return publicationDto(target);
  });
}

export function verifyPublication(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const now = input.now ?? new Date();
    let target = yield* requireOwnedPublication(
      repository,
      input.publicationId,
      input.principal.userId,
    );

    if (target.publication.state === "disabled" || target.publication.state === "disabling") {
      return yield* new PublicationConflictError({ reason: "publication_not_active" });
    }

    if (target.domain.kind === "custom" && target.domain.verificationState !== "verified") {
      let domain = yield* ensureCustomDomainVerification({
        repository,
        provider,
        domain: target.domain,
        publicationHostname: target.publication.hostname,
        ownerUserId: input.principal.userId,
        now,
      });
      const verificationId = domain.providerVerificationId;
      if (!verificationId) {
        return yield* new PublicationInvariantError({
          reason: "provider_verification_id_missing",
        });
      }
      if (domain.verificationState !== "verified") {
        const ownership = yield* provider.completeDomainVerification(verificationId);
        if (
          ownership.verificationId !== verificationId ||
          normalizePublicationHostname(ownership.domain) !== target.domain.hostname
        ) {
          return yield* new PublicationInvariantError({
            reason: "provider_verification_mismatch",
          });
        }
        domain = yield* repository.updateDomainState({
          id: domain.id,
          ownerUserId: input.principal.userId,
          verificationState: "verified",
          certificateState: "pending",
          now,
        });
      }
      target = { ...target, domain };
    }

    if (target.publication.state === "active") {
      const certificate = target.domain.kind === "custom"
        ? yield* provider.getWildcardCertificateStatus(target.domain.hostname)
        : yield* provider.getCertificateStatus(target.publication.hostname);
      const domain = yield* repository.updateDomainState({
        id: target.domain.id,
        ownerUserId: input.principal.userId,
        certificateState: certificate.state,
        now,
      });
      return publicationDto({ ...target, domain });
    }

    target = yield* provisionReservedPublication({
      repository,
      provider,
      target,
      ownerUserId: input.principal.userId,
      forwardAuth: input.forwardAuth,
      now,
    });
    return publicationDto(target);
  });
}

export function updatePublicationAccess(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly accessMode: CloudVmPublicationAccessMode;
  readonly teamId?: string | null;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const now = input.now ?? new Date();
    const access = yield* validateAccessPolicy(
      input.accessMode,
      input.teamId,
      input.principal.teamIds,
    );
    let target = yield* requireOwnedPublication(
      repository,
      input.publicationId,
      input.principal.userId,
    );
    const publication = target.publication;
    if (publication.state !== "active") {
      return yield* new PublicationProvisioningBusyError({
        retryAt: new Date(now.getTime() + 5_000),
      });
    }
    if (
      publication.accessMode === access.accessMode &&
      publication.teamId === access.teamId &&
      ((access.accessMode === "public" && publication.providerForwardAuthId === null) ||
        (access.accessMode !== "public" && publication.providerForwardAuthId !== null))
    ) {
      return publicationDto(target);
    }

    return yield* withVmPublicationOperationLease({
      repository,
      publicationId: publication.id,
      ownerUserId: input.principal.userId,
      now,
    }, Effect.gen(function* () {
      const providerVmId = yield* requireProviderVmId(target);
      const tlsRuleId = yield* requireProviderTlsRuleId(publication);
      const wasPublic = publication.accessMode === "public";
      const willBePublic = access.accessMode === "public";

      // A protected -> public transition commits policy before provider I/O. If
      // that I/O failed, a retry sees public policy with the old applied marker
      // and finishes detaching the edge gate without another revision bump.
      if (wasPublic && willBePublic && publication.providerForwardAuthId !== null) {
        yield* provider.updateTlsRule(tlsRuleId, {
          hostname: target.publication.hostname,
          providerVmId,
          port: publication.port,
          forwardAuthId: null,
        });
        const recovered = yield* repository.recordAppliedForwardAuth({
          id: publication.id,
          expectedRoutingRevision: publication.routingRevision,
          providerForwardAuthId: null,
          now,
        });
        return publicationDto({ ...target, publication: recovered });
      }

      if (wasPublic && !willBePublic) {
        // Fail closed: protect the edge first. Until the DB commit, authenticated
        // browsers are still evaluated under the old public policy.
        const forwardAuthId = yield* ensureSharedForwardAuth({
          repository,
          provider,
          providerId: target.vm.provider,
          config: input.forwardAuth,
          now,
        });
        yield* provider.updateTlsRule(tlsRuleId, {
          hostname: target.publication.hostname,
          providerVmId,
          port: publication.port,
          forwardAuthId,
        });
        const updated = yield* repository.commitAccessPolicy({
          id: publication.id,
          ownerUserId: input.principal.userId,
          expectedRoutingRevision: publication.routingRevision,
          accessMode: access.accessMode,
          teamId: access.teamId,
          appliedProviderForwardAuthId: forwardAuthId,
          now,
        });
        yield* repository.revokePublicationSessions({
          publicationId: updated.id,
          now,
        });
        return publicationDto({ ...target, publication: updated });
      }

      if (!wasPublic && willBePublic) {
        // Commit the permissive policy and rotate its revision before removing
        // the edge gate, so a request is never routed under stale protected policy.
        const committed = yield* repository.commitAccessPolicy({
          id: publication.id,
          ownerUserId: input.principal.userId,
          expectedRoutingRevision: publication.routingRevision,
          accessMode: "public",
          teamId: null,
          now,
        });
        yield* repository.revokePublicationSessions({
          publicationId: committed.id,
          now,
        });
        yield* provider.updateTlsRule(tlsRuleId, {
          hostname: target.publication.hostname,
          providerVmId,
          port: publication.port,
          forwardAuthId: null,
        });
        const updated = yield* repository.recordAppliedForwardAuth({
          id: committed.id,
          expectedRoutingRevision: committed.routingRevision,
          providerForwardAuthId: null,
          now,
        });
        return publicationDto({ ...target, publication: updated });
      }

      // Personal/team changes share the same edge configuration. A revision bump
      // plus session revocation makes the authorization change immediate.
      const updated = yield* repository.commitAccessPolicy({
        id: publication.id,
        ownerUserId: input.principal.userId,
        expectedRoutingRevision: publication.routingRevision,
        accessMode: access.accessMode,
        teamId: access.teamId,
        now,
      });
      yield* repository.revokePublicationSessions({ publicationId: updated.id, now });
      target = { ...target, publication: updated };
      return publicationDto(target);
    }));
  });
}

export function deletePublication(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const provider = yield* VmPublicationProvider;
    const now = input.now ?? new Date();
    const target = yield* requireOwnedPublication(
      repository,
      input.publicationId,
      input.principal.userId,
    );
    if (target.publication.state === "disabled") {
      return { deleted: true as const, id: target.publication.id };
    }
    // `disable` intent lets a retry resume a row left `disabling` by a sweep
    // that failed after the state change, so the provider rule is never orphaned.
    return yield* withVmPublicationOperationLease({
      repository,
      publicationId: target.publication.id,
      ownerUserId: input.principal.userId,
      now,
      intent: "disable",
    }, Effect.gen(function* () {
      const disabling = yield* repository.beginDisablePublication({
        id: target.publication.id,
        ownerUserId: input.principal.userId,
        now,
      });

      // The state/revision mutation makes forward-auth resolution fail closed
      // before any provider rule is removed.
      yield* repository.revokePublicationSessions({
        publicationId: disabling.id,
        now,
      });
      // Sweep by exact hostname, not just the persisted id. Reconcile may have
      // created a rule immediately before a process died, and retries can leave
      // duplicate exact-host rules that no local row names yet.
      yield* provider.deleteTlsRulesForHostname(target.publication.hostname);
      yield* repository.finishDisablePublication({ id: disabling.id, now });
      return { deleted: true as const, id: disabling.id };
    }));
  });
}

function validateAccessPolicy(
  accessMode: string,
  teamId: string | null | undefined,
  allowedTeamIds: readonly string[],
) {
  return Effect.gen(function* () {
    if (accessMode !== "personal" && accessMode !== "team" && accessMode !== "public") {
      return yield* new PublicationInputError({
        reason: "invalid_access_mode",
        field: "accessMode",
      });
    }
    const normalizedTeamId = teamId?.trim() || null;
    if (accessMode === "team" && !normalizedTeamId) {
      return yield* new PublicationInputError({ reason: "team_required", field: "teamId" });
    }
    if (accessMode !== "team" && normalizedTeamId) {
      return yield* new PublicationInputError({
        reason: "invalid_access_mode",
        field: "teamId",
      });
    }
    if (
      accessMode === "team" &&
      normalizedTeamId &&
      !allowedTeamIds.includes(normalizedTeamId)
    ) {
      return yield* new PublicationInputError({ reason: "team_not_allowed", field: "teamId" });
    }
    return { accessMode, teamId: normalizedTeamId } as const;
  });
}

/** A deployment misconfiguration must fail before any hostname is reserved. */
function normalizedGeneratedPublicationDomain(value: string | undefined) {
  return Effect.gen(function* () {
    const domain = normalizePublicationHostname(
      value ?? DEFAULT_GENERATED_PUBLICATION_DOMAIN,
    );
    if (!domain) {
      return yield* new PublicationConfigurationError({
        reason: "invalid_generated_domain",
      });
    }
    return domain;
  });
}

function normalizedRequestedHostname(
  value: string,
  customerProvided: boolean,
  generatedDomain: string,
) {
  return Effect.gen(function* () {
    const hostname = normalizePublicationHostname(value);
    if (!hostname) {
      return yield* new PublicationInputError({
        reason: "invalid_hostname",
        field: "hostname",
      });
    }
    // Customers cannot verify Freestyle's platform zone or the CMUX generated
    // zone, so neither may be selected as a custom hostname.
    if (
      customerProvided &&
      (isFreestylePlatformHostname(hostname) ||
        isWithinGeneratedPublicationZone(hostname, generatedDomain))
    ) {
      return yield* new PublicationInputError({
        reason: "generated_hostname_reserved",
        field: "hostname",
      });
    }
    return hostname;
  });
}

/** The generated zone apex and everything below it stay reserved for CMUX. */
export function isWithinGeneratedPublicationZone(
  hostname: string,
  generatedDomain: string,
): boolean {
  return hostname === generatedDomain || hostname.endsWith(`.${generatedDomain}`);
}

const GENERATED_HOSTNAME_ATTEMPTS = 6;
const GENERATED_HOSTNAME_PLAIN_ATTEMPTS = 3;

/**
 * Friendly names such as `laughing-green-elephants.cmux.sh`. After a few
 * collisions a short random suffix keeps a busy zone minting quickly instead
 * of exhausting the vocabulary.
 */
function generatedPublicationHostname(generatedDomain: string, attempt: number): string {
  const suffix = attempt < GENERATED_HOSTNAME_PLAIN_ATTEMPTS
    ? ""
    : `-${randomUUID().replaceAll("-", "").slice(0, 4)}`;
  return `${friendlyPublicationLabel()}${suffix}.${generatedDomain}`;
}

/**
 * Reserve the publication hostname. A generated name is minted here and, when
 * another account already holds it, minted again: the database's global
 * hostname claim is the arbiter, and a customer never sees another tenant's
 * random collision. Customer-chosen hostnames surface their conflicts as-is.
 */
function reservePublicationTarget(input: {
  readonly repository: CloudVmPublicationRepositoryShape;
  readonly principal: PublicationPrincipal;
  readonly providerId: ProviderId;
  readonly providerVmId: string;
  readonly port: number;
  readonly access: { readonly accessMode: CloudVmPublicationAccessMode; readonly teamId: string | null };
  readonly hostname: string | undefined;
  readonly generatedHostname: string | undefined;
  readonly generatedDomain: string;
  readonly now: Date;
}) {
  return Effect.gen(function* () {
    const isCustom = input.hostname !== undefined;
    const retryGeneratedName = !isCustom && input.generatedHostname === undefined;
    const ownedDomains = isCustom
      ? yield* input.repository.listOwnedDomains(input.principal.userId)
      : [];
    for (let attempt = 0; ; attempt++) {
      const hostname = yield* normalizedRequestedHostname(
        input.hostname ??
          input.generatedHostname ??
          generatedPublicationHostname(input.generatedDomain, attempt),
        isCustom,
        input.generatedDomain,
      );
      const coveringDomain = isCustom
        ? longestCoveringDomain(ownedDomains, input.providerId, hostname)
        : null;
      const shared = {
        ownerUserId: input.principal.userId,
        billingTeamId: input.principal.billingTeamId,
        teamIds: input.principal.teamIds,
        provider: input.providerId,
        providerVmId: input.providerVmId,
        hostname,
        port: input.port,
        accessMode: input.access.accessMode,
        teamId: input.access.teamId,
        now: input.now,
      } as const;
      const reservation = yield* Effect.either(
        coveringDomain
          ? input.repository.reservePublication({ ...shared, domainId: coveringDomain.id })
          : input.repository.reservePublicationWithNewDomain({
            ...shared,
            domainHostname: hostname,
            kind: isCustom ? "custom" : "generated",
          }),
      );
      if (reservation._tag === "Right") return reservation.right;
      const collided =
        reservation.left._tag === "PublicationConflictError" &&
        reservation.left.reason === "hostname_taken";
      if (!retryGeneratedName || !collided || attempt + 1 >= GENERATED_HOSTNAME_ATTEMPTS) {
        return yield* Effect.fail(reservation.left);
      }
    }
  });
}

function longestCoveringDomain(
  domains: readonly CloudVmDomainRow[],
  provider: ProviderId,
  publicationHostname: string,
): CloudVmDomainRow | null {
  // A verified zone always wins over a pending one, so a stale pending
  // attempt cannot strand a hostname that a verified parent already covers;
  // among equals the most specific zone is reused.
  return [...domains]
    .filter((domain) =>
      domain.provider === provider &&
      domain.kind === "custom" &&
      domainCoversPublicationHostname(domain.hostname, publicationHostname)
    )
    .sort((left, right) =>
      Number(right.verificationState === "verified") -
        Number(left.verificationState === "verified") ||
      right.hostname.length - left.hostname.length
    )[0] ?? null;
}

function domainCoversPublicationHostname(
  domainHostname: string,
  publicationHostname: string,
): boolean {
  if (publicationHostname === domainHostname) return true;
  if (!publicationHostname.endsWith(`.${domainHostname}`)) return false;
  return publicationHostname.slice(0, -(domainHostname.length + 1)).includes(".") === false;
}

function ensureCustomDomainVerification(input: {
  readonly repository: CloudVmPublicationRepositoryShape;
  readonly provider: VmPublicationProviderShape;
  readonly domain: CloudVmDomainRow;
  readonly publicationHostname: string;
  readonly ownerUserId: string;
  readonly now: Date;
}) {
  return Effect.gen(function* () {
    let verification: PublicationDomainVerification | null = null;
    if (input.domain.providerVerificationId) {
      verification = yield* input.provider.getDomainVerification({
        domainOrVerificationId: input.domain.providerVerificationId,
        hostname: input.publicationHostname,
      });
      if (
        verification &&
        (verification.verificationId !== input.domain.providerVerificationId ||
          verification.domain !== input.domain.hostname)
      ) {
        return yield* new PublicationInvariantError({
          reason: "provider_verification_mismatch",
        });
      }
    }
    if (!verification) {
      verification = yield* input.provider.createDomainVerification({
        domain: input.domain.hostname,
        hostname: input.publicationHostname,
      });
    }
    return yield* input.repository.updateDomainState({
      id: input.domain.id,
      ownerUserId: input.ownerUserId,
      providerVerificationId: verification.verificationId,
      verificationState: verification.state,
      verificationRecords: verificationRecords(verification),
      now: input.now,
    });
  });
}

function provisionReservedPublication(input: {
  readonly repository: CloudVmPublicationRepositoryShape;
  readonly provider: VmPublicationProviderShape;
  readonly target: CloudVmPublicationTarget;
  readonly ownerUserId: string;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly now: Date;
}) {
  return Effect.gen(function* () {
    const providerVmId = yield* requireProviderVmId(input.target);
    return yield* withVmPublicationOperationLease({
      repository: input.repository,
      publicationId: input.target.publication.id,
      ownerUserId: input.ownerUserId,
      now: input.now,
    }, Effect.gen(function* () {
      let domain = input.target.domain;
      if (domain.kind === "custom") {
        if (domain.verificationState !== "verified") {
          return yield* new PublicationConflictError({
            reason: "publication_not_active",
          });
        }
        // One verified owner-scoped zone gets one reusable wildcard. The call
        // is idempotent, so it also repairs a crash between local verification
        // promotion and the provider certificate request.
        yield* input.provider.requestWildcardCertificate(domain.hostname);
        const wildcard = yield* input.provider.getWildcardCertificateStatus(
          domain.hostname,
        );
        domain = yield* input.repository.updateDomainState({
          id: domain.id,
          ownerUserId: input.ownerUserId,
          certificateState: wildcard.state,
          now: input.now,
        });
      }
      const forwardAuthId = input.target.publication.accessMode === "public"
        ? null
        : yield* ensureSharedForwardAuth({
          repository: input.repository,
          provider: input.provider,
          providerId: input.target.vm.provider,
          config: input.forwardAuth,
          now: input.now,
        });
      const reconciled = yield* input.provider.reconcileTlsRule(
        input.target.publication.providerTlsRuleId,
        {
          hostname: input.target.publication.hostname,
          providerVmId,
          port: input.target.publication.port,
          forwardAuthId,
        },
      );
      const publication = yield* input.repository.recordProvisioningTlsRule({
        id: input.target.publication.id,
        ownerUserId: input.ownerUserId,
        expectedRoutingRevision: input.target.publication.routingRevision,
        providerTlsRuleId: reconciled.rule.tlsRuleId,
        providerForwardAuthId: forwardAuthId,
        now: input.now,
      });
      const certificate = yield* input.provider.getCertificateStatus(
        input.target.publication.hostname,
      );
      if (domain.kind === "generated") {
        domain = yield* input.repository.updateDomainState({
          id: domain.id,
          ownerUserId: input.ownerUserId,
          certificateState: certificate.state,
          now: input.now,
        });
      }
      if (!certificate.ready) {
        return { ...input.target, publication, domain };
      }
      const active = yield* input.repository.activatePublication({
        id: publication.id,
        ownerUserId: input.ownerUserId,
        expectedRoutingRevision: publication.routingRevision,
        providerTlsRuleId: reconciled.rule.tlsRuleId,
        providerForwardAuthId: forwardAuthId,
        now: input.now,
      });
      return { ...input.target, publication: active, domain };
    }));
  });
}

function withVmPublicationOperationLease<A, E, R>(
  input: {
    readonly repository: CloudVmPublicationRepositoryShape;
    readonly publicationId: string;
    readonly ownerUserId: string;
    readonly now: Date;
    readonly intent?: "mutate" | "disable";
  },
  operation: Effect.Effect<A, E, R>,
) {
  return Effect.gen(function* () {
    const leaseId = randomUUID();
    const claim = yield* input.repository.claimVmPublicationOperation({
      publicationId: input.publicationId,
      ownerUserId: input.ownerUserId,
      leaseId,
      intent: input.intent,
      now: input.now,
      leaseExpiresAt: new Date(
        input.now.getTime() + VM_PUBLICATION_OPERATION_LEASE_MS,
      ),
    });
    if (claim.kind === "in_progress") {
      return yield* new PublicationProvisioningBusyError({ retryAt: claim.retryAt });
    }
    return yield* operation.pipe(Effect.ensuring(
      input.repository.releaseVmPublicationOperation({
        publicationId: input.publicationId,
        leaseId,
        now: input.now,
      }).pipe(Effect.ignore),
    ));
  });
}

function ensureSharedForwardAuth(input: {
  readonly repository: CloudVmPublicationRepositoryShape;
  readonly provider: VmPublicationProviderShape;
  readonly providerId: ProviderId;
  readonly config?: PublicationForwardAuthConfig;
  readonly now: Date;
}) {
  return Effect.gen(function* () {
    const config = input.config;
    if (!config?.serviceToken.trim()) {
      return yield* new PublicationConfigurationError({
        reason: "forward_auth_not_configured",
      });
    }
    let parsed: URL;
    try {
      parsed = new URL(config.url);
    } catch {
      return yield* new PublicationConfigurationError({ reason: "invalid_auth_origin" });
    }
    if (parsed.protocol !== "https:") {
      return yield* new PublicationConfigurationError({ reason: "invalid_auth_origin" });
    }

    const leaseId = randomUUID();
    const claim = yield* input.repository.claimProviderForwardAuth({
      provider: input.providerId,
      leaseId,
      now: input.now,
      leaseExpiresAt: new Date(input.now.getTime() + FORWARD_AUTH_LEASE_MS),
    });
    if (claim.kind === "in_progress") {
      return yield* new PublicationProvisioningBusyError({ retryAt: claim.retryAt });
    }
    const existingId = claim.config.providerForwardAuthId;
    const ensured = yield* input.provider.ensureSharedForwardAuth({
      existingForwardAuthId: existingId,
      url: parsed.href,
      serviceToken: config.serviceToken,
    }).pipe(
      Effect.tapError(() =>
        claim.kind === "claimed"
          ? input.repository.releaseProviderForwardAuthClaim({
            provider: input.providerId,
            leaseId,
            now: input.now,
          }).pipe(Effect.ignore)
          : Effect.void,
      ),
    );

    if (claim.kind === "claimed") {
      const completed = yield* input.repository.completeProviderForwardAuth({
        provider: input.providerId,
        leaseId,
        providerForwardAuthId: ensured.forwardAuthId,
        now: input.now,
      });
      return completed.providerForwardAuthId!;
    }
    if (existingId !== ensured.forwardAuthId) {
      const replaced = yield* input.repository.replaceProviderForwardAuth({
        provider: input.providerId,
        expectedProviderForwardAuthId: existingId!,
        providerForwardAuthId: ensured.forwardAuthId,
        now: input.now,
      });
      return replaced.providerForwardAuthId!;
    }
    return ensured.forwardAuthId;
  });
}

function requireOwnedPublication(
  repository: CloudVmPublicationRepositoryShape,
  publicationId: string,
  ownerUserId: string,
) {
  return Effect.gen(function* () {
    const target = yield* repository.findOwnedPublication({ id: publicationId, ownerUserId });
    if (!target) {
      return yield* new PublicationNotFoundError({ resource: "publication" });
    }
    return target;
  });
}

function requireProviderVmId(target: CloudVmPublicationTarget) {
  return target.vm.providerVmId
    ? Effect.succeed(target.vm.providerVmId)
    : Effect.fail(new PublicationInvariantError({ reason: "provider_vm_id_missing" }));
}

function requireProviderTlsRuleId(publication: CloudVmPublicationRow) {
  return publication.providerTlsRuleId
    ? Effect.succeed(publication.providerTlsRuleId)
    : Effect.fail(new PublicationInvariantError({ reason: "provider_tls_rule_id_missing" }));
}

function verificationRecords(
  verification: PublicationDomainVerification,
): readonly CloudVmDomainVerificationRecord[] {
  return [
    verification.dnsInstructions.verification,
    verification.dnsInstructions.routing,
    verification.dnsInstructions.certificate,
  ].map(persistedDnsInstruction);
}

function persistedDnsInstruction(
  instruction: PublicationDnsInstruction,
): CloudVmDomainVerificationRecord {
  return {
    purpose: instruction.purpose,
    recordTypes: [...instruction.recordTypes],
    name: instruction.name,
    value: instruction.value,
  };
}

function publicationDto(target: CloudVmPublicationTarget): PublicationDto {
  return {
    id: target.publication.id,
    hostname: target.publication.hostname,
    url: `https://${target.publication.hostname}`,
    domainKind: target.domain.kind,
    vmId: target.vm.providerVmId ?? target.vm.id,
    port: target.publication.port,
    accessMode: target.publication.accessMode,
    teamId: target.publication.teamId,
    state: target.publication.state,
    routingRevision: target.publication.routingRevision,
    verification: publicationVerificationDto(
      target.domain,
      target.publication.hostname,
    ),
  };
}

function publicationVerificationDto(
  domain: CloudVmDomainRow,
  publicationHostname: string,
): PublicationVerificationDto | null {
  if (domain.kind !== "custom" || !domain.providerVerificationId) return null;
  const verification = domain.verificationRecords.find(
    (record) => record.purpose === "verification",
  );
  const routing = publicationRoutingDnsInstruction(
    publicationHostname,
    domain.hostname,
  );
  const certificate = domain.verificationRecords.find(
    (record) => record.purpose === "certificate",
  );
  if (!verification || !routing || !certificate) return null;
  return {
    verificationId: domain.providerVerificationId,
    domain: domain.hostname,
    state: domain.verificationState,
    dnsInstructions: { verification, routing, certificate },
  };
}
