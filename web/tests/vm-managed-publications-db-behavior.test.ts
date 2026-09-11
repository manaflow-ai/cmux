import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import * as Effect from "effect/Effect";
import { closeCloudDbForTests } from "../db/client";
import { reserveManagedPublication, type ManagedPublicationInput } from "../services/vm-publications/managedRepository";
import { CloudVmPublicationRepository, CloudVmPublicationRepositoryLive, type CloudVmPublicationRepositoryShape } from "../services/vm-publications/repository";
import { evaluatePublicationRequest, resolvePublicationAccess, PublicationViewerResolver } from "../services/vm-publications/auth";
import { hashPublicationToken, publicationPkceChallenge, randomPublicationToken } from "../services/vm-publications/security";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
const now = new Date("2026-09-05T01:00:00Z");
let db: Sql;
let repository: CloudVmPublicationRepositoryShape;
const owners: string[] = [];

beforeAll(async () => {
  if (process.env.CMUX_DB_TEST !== "1") return;
  db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 6 });
  repository = await Effect.runPromise(CloudVmPublicationRepository.pipe(Effect.provide(CloudVmPublicationRepositoryLive)));
});
afterAll(async () => {
  if (!db) return;
  for (const owner of owners) {
    await db`delete from cloud_vm_publications where owner_user_id = ${owner}`;
    await db`delete from cloud_organizations where owner_user_id = ${owner}`;
    await db`delete from cloud_vms where user_id = ${owner}`;
  }
  await closeCloudDbForTests();
  await db.end();
});

async function seed(name = "lawrence"): Promise<ManagedPublicationInput> {
  const ownerUserId = randomUUID(); owners.push(ownerUserId);
  const providerVmId = `vm-${randomUUID()}`;
  await db`insert into cloud_vms(user_id, billing_team_id, provider, provider_vm_id, image_id, status, slug)
    values (${ownerUserId}, ${ownerUserId}, 'freestyle', ${providerVmId}, 'test-image', 'running', 'hello')`;
  return { ownerUserId, billingTeamId: ownerUserId, teamIds: [], providerVmId, organizationName: name, port: 3000, generatedDomain: "cmux.sh", accessMode: "personal", teamId: null, now };
}

async function activate(input: ManagedPublicationInput) {
  const target = await reserveManagedPublication(input);
  const publication = await Effect.runPromise(repository.activatePublication({
    id: target.publication.id, ownerUserId: input.ownerUserId, expectedRoutingRevision: 1,
    providerTlsRuleId: `tls-${randomUUID()}`, providerForwardAuthId: "shared-auth", now,
  }));
  return { ...target, publication };
}

describe("managed port publications in Postgres", () => {
  dbTest("reserves the exact hostname without creating a managed zone and preserves policy on retry", async () => {
    const input = await seed();
    const first = await reserveManagedPublication(input);
    expect(first.publication.hostname).toBe("hello--lawrence--3000.cmux.sh");
    expect(first.domain).toBeNull();
    expect(first.publication.domainId).toBeNull();
    const second = await reserveManagedPublication({ ...input, port: 8080 });
    expect(second.publication.hostname).toBe("hello--lawrence--8080.cmux.sh");
    const retried = await reserveManagedPublication({ ...input, accessMode: "public" });
    expect(retried.publication.id).toBe(first.publication.id);
    expect(retried.publication.accessMode).toBe("personal");
    expect(await db`select id from cloud_vm_domains where owner_user_id = ${input.ownerUserId}`).toHaveLength(0);
    expect(await db`select scope_id from cloud_organizations where owner_user_id = ${input.ownerUserId}`).toHaveLength(1);
  });
  dbTest("serializes simultaneous requests and organization slug collisions", async () => {
    const a = await seed(`org-${randomUUID().slice(0, 8)}`);
    const b = await seed(a.organizationName);
    const [first, repeated, other] = await Promise.all([reserveManagedPublication(a), reserveManagedPublication(a), reserveManagedPublication(b)]);
    expect(first.publication.id).toBe(repeated.publication.id);
    expect(first.publication.hostname).not.toBe(other.publication.hostname);
    await expect(reserveManagedPublication({ ...a, organizationSlug: "different" })).rejects.toMatchObject({ reason: "organization_slug_reserved" });
  });
  dbTest("rejects foreign VMs before reserving organization identity", async () => {
    const input = await seed(`scope-${randomUUID().slice(0, 8)}`);
    const stranger = randomUUID();
    await expect(reserveManagedPublication({ ...input, ownerUserId: stranger, billingTeamId: stranger })).rejects.toMatchObject({ resource: "vm" });
    expect(await db`select scope_id from cloud_organizations where owner_user_id = ${stranger}`).toHaveLength(0);
  });
  dbTest("checks verified email, exact publication, expiry, and revocation for existing sessions", async () => {
    const input = await seed(`auth-${randomUUID().slice(0, 8)}`);
    const first = await activate(input);
    const other = await activate({ ...input, port: 8080 });
    const guest = randomUUID();
    const sessionToken = randomPublicationToken();
    await db`insert into cloud_vm_publication_sessions(token_hash, publication_id, user_id, routing_revision, created_at, expires_at)
      values (${hashPublicationToken(sessionToken)}, ${first.publication.id}, ${guest}, 1, ${now}, ${new Date(now.getTime() + 60000)})`;
    const grant = { publicationId: first.publication.id, ownerUserId: input.ownerUserId, email: "guest@example.com", now, expiresAt: new Date(now.getTime() + 30000), revoke: false };
    await Effect.runPromise(repository.setEmailGrant(grant));
    let verifiedEmails = ["guest@example.com"];
    const check = (ruleId: string, at = now) => Effect.runPromise(evaluatePublicationRequest({ providerTlsRuleId: ruleId, sessionToken, method: "POST", now: at }).pipe(
      Effect.provideService(CloudVmPublicationRepository, repository),
      Effect.provideService(PublicationViewerResolver, { resolve: () => Effect.succeed({ userId: guest, teamIds: [], verifiedEmails }) }),
    ));
    expect(await check(first.publication.providerTlsRuleId!)).toEqual({ kind: "allow" });
    expect(await check(other.publication.providerTlsRuleId!)).toEqual({ kind: "unauthorized" });
    verifiedEmails = [];
    expect(await check(first.publication.providerTlsRuleId!)).toEqual({ kind: "unauthorized" });
    verifiedEmails = ["guest@example.com"];
    expect(await check(first.publication.providerTlsRuleId!, grant.expiresAt)).toEqual({ kind: "unauthorized" });
    await Effect.runPromise(repository.setEmailGrant({ ...grant, revoke: true }));
    expect(await check(first.publication.providerTlsRuleId!)).toEqual({ kind: "unauthorized" });
    expect(await Effect.runPromise(repository.listOwnedPublications(guest))).toEqual([]);
    await expect(reserveManagedPublication({ ...input, ownerUserId: guest, billingTeamId: guest })).rejects.toMatchObject({ resource: "vm" });
    const change = await Effect.runPromise(Effect.either(repository.setEmailGrant({ ...grant, ownerUserId: guest })));
    expect(change._tag).toBe("Left");
  });

  dbTest("uses current VM ownership for personal-mode sessions and sign-in handoffs", async () => {
    const input = await seed(`team-${randomUUID().slice(0, 8)}`);
    const team = randomUUID();
    await db`update cloud_vms set billing_team_id = ${team} where user_id = ${input.ownerUserId}`;
    const target = await activate({ ...input, billingTeamId: team, teamIds: [team] });
    const sessionToken = randomPublicationToken();
    const transaction = randomPublicationToken();
    const state = randomPublicationToken();
    await db`insert into cloud_vm_publication_sessions(token_hash, publication_id, user_id, routing_revision, created_at, expires_at)
      values (${hashPublicationToken(sessionToken)}, ${target.publication.id}, ${input.ownerUserId}, 1, ${now}, ${new Date(now.getTime() + 60000)})`;
    await Effect.runPromise(repository.createAuthTransaction({
      publicationId: target.publication.id, transactionHash: hashPublicationToken(transaction),
      stateHash: hashPublicationToken(state), pkceChallenge: publicationPkceChallenge(randomPublicationToken()),
      hostname: target.publication.hostname, returnPath: "/", now, expiresAt: new Date(now.getTime() + 60000),
    }));
    let teamIds = [team];
    const services = Effect.provideService(PublicationViewerResolver, {
      resolve: () => Effect.sync(() => ({ userId: input.ownerUserId, teamIds, verifiedEmails: ["owner@example.com"] })),
    });
    const check = () => Effect.runPromise(evaluatePublicationRequest({
      providerTlsRuleId: target.publication.providerTlsRuleId!, sessionToken, method: "POST", now,
    }).pipe(Effect.provideService(CloudVmPublicationRepository, repository), services));
    expect(await check()).toEqual({ kind: "allow" });
    teamIds = [];
    expect(await check()).toEqual({ kind: "unauthorized" });
    const handoff = await Effect.runPromise(resolvePublicationAccess({
      transaction, state, now,
      user: { userId: input.ownerUserId, teamIds: [team], identity: "owner@example.com" },
    }).pipe(Effect.provideService(CloudVmPublicationRepository, repository), services));
    expect(handoff.kind).toBe("denied");
    // An explicit grant remains an independent publication-only audience.
    await Effect.runPromise(repository.setEmailGrant({
      publicationId: target.publication.id, ownerUserId: input.ownerUserId,
      email: "owner@example.com", expiresAt: null, revoke: false, now,
    }));
    expect(await check()).toEqual({ kind: "allow" });
  });
});
