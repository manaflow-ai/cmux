// Sharing app-started chats on a team Cloud machine (Leo, 2026-10-31: "we
// can't simply block always"). A grant makes one more teammate `owner` in
// the attach answer, so cmux-tui's guarded start accepts them; only the
// machine's creator or a team admin may grant or take it back, and only to a
// current member of the machine's team. Mirrors cmux-platform's
// machineAccess start_chat and share_chat.
import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { grantVmChat, listVmChatGrants, revokeVmChat, type VmTeamAdminCheck } from "../services/vms/chatGrants";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmChatGrantRow, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import type { VmTeamDirectory } from "../services/vms/teamDirectory";

const NOW = new Date("2026-01-01T00:00:00.000Z");
const CREATOR = "user-creator";
const ADMIN = "user-admin";
const MEMBER = "user-member";
const OUTSIDER = "user-outsider";
const TEAM = "team-shared";

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000601",
    userId: CREATOR,
    billingTeamId: TEAM,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "vm-share",
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: NOW,
    updatedAt: NOW,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ownerTeamId: TEAM,
    coderouterPoolId: null,
    ...overrides,
  };
}

const teamVm = row();
const personalVm = row({ billingTeamId: CREATOR, ownerTeamId: CREATOR });

/** An in-memory grant store over one machine row. */
function store(vm: CloudVmRow, options: { failReads?: true; noGrantMethods?: true } = {}) {
  const grants = new Map<string, CloudVmChatGrantRow>();
  const repo = {
    findUserVm: () => Effect.succeed(vm),
    ...(options.noGrantMethods ? {} : {
      listVmChatGrants: (vmId: string) => Effect.succeed([...grants.values()].filter((grant) => grant.vmId === vmId)),
      putVmChatGrant: (input: { vmId: string; userId: string; grantedBy: string }) => {
        const key = `${input.vmId}:${input.userId}`;
        const existing = grants.get(key);
        if (existing) return Effect.succeed(existing);
        const grant = { ...input, createdAt: NOW };
        grants.set(key, grant);
        return Effect.succeed(grant);
      },
      deleteVmChatGrant: (input: { vmId: string; userId: string }) => Effect.succeed(grants.delete(`${input.vmId}:${input.userId}`)),
    }),
  } as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, {} as unknown as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  return { grants, layer };
}

function directory(answer: { members?: readonly string[] | null; error?: Error }) {
  const teamDirectory: VmTeamDirectory = {
    async listMemberIds() {
      if (answer.error) throw answer.error;
      return answer.members ?? null;
    },
  };
  return teamDirectory;
}

const members = directory({ members: [CREATOR, ADMIN, MEMBER] });
const admins = (ids: readonly string[]): VmTeamAdminCheck => async (_teamId, userId) => ids.includes(userId);

function shareInput(caller: string, target: string, overrides: Partial<{ teamDirectory: VmTeamDirectory; isTeamAdmin: VmTeamAdminCheck }> = {}) {
  return {
    userId: caller,
    billingTeamId: TEAM,
    teamIds: [TEAM],
    providerVmId: "vm-share",
    targetUserId: target,
    teamDirectory: overrides.teamDirectory ?? members,
    isTeamAdmin: overrides.isTeamAdmin ?? admins([ADMIN]),
  };
}

function run<A, E>(program: Effect.Effect<A, E, VmRepository | VmProviderGateway | VmBillingGateway>, layer: Layer.Layer<VmRepository | VmProviderGateway | VmBillingGateway>) {
  return Effect.runPromise(program.pipe(Effect.provide(layer)));
}

describe("granting chat starts on a team machine", () => {
  test("the creator shares with a teammate, and the share lists", async () => {
    const { grants, layer } = store(teamVm);
    const granted = await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer);
    expect(granted).toEqual({ ok: true, value: { userId: MEMBER, grantedBy: CREATOR, createdAt: NOW.toISOString() } });
    expect(grants.size).toBe(1);
    const listed = await run(listVmChatGrants(shareInput(MEMBER, "")), layer);
    expect(listed).toEqual({ ok: true, value: [{ userId: MEMBER, grantedBy: CREATOR, createdAt: NOW.toISOString() }] });
  });

  test("granting twice keeps the first grant", async () => {
    const { grants, layer } = store(teamVm);
    await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer);
    const again = await run(grantVmChat(shareInput(ADMIN, MEMBER)), layer);
    expect(again).toMatchObject({ ok: true, value: { userId: MEMBER, grantedBy: CREATOR } });
    expect(grants.size).toBe(1);
  });

  test("a team admin may share a teammate's machine; a plain member may not", async () => {
    const { layer } = store(teamVm);
    expect(await run(grantVmChat(shareInput(ADMIN, MEMBER)), layer)).toMatchObject({ ok: true, value: { grantedBy: ADMIN } });
    expect(await run(grantVmChat(shareInput(MEMBER, ADMIN)), layer))
      .toMatchObject({ ok: false, refusal: { status: 403, error: "vm_chat_share_forbidden" } });
  });

  test("a creator who left the team shares nothing, unless they are an admin there", async () => {
    const { layer } = store(teamVm);
    const left = directory({ members: [ADMIN, MEMBER] });
    expect(await run(grantVmChat(shareInput(CREATOR, MEMBER, { teamDirectory: left })), layer))
      .toMatchObject({ ok: false, refusal: { status: 403 } });
    // A missing team shares nothing either.
    expect(await run(grantVmChat(shareInput(CREATOR, MEMBER, { teamDirectory: directory({ members: null }) })), layer))
      .toMatchObject({ ok: false, refusal: { status: 403 } });
  });

  test("the grant is only for a current member of the machine's team, and never the creator", async () => {
    const { grants, layer } = store(teamVm);
    expect(await run(grantVmChat(shareInput(CREATOR, OUTSIDER)), layer))
      .toMatchObject({ ok: false, refusal: { status: 409, error: "vm_chat_grant_not_member" } });
    expect(await run(grantVmChat(shareInput(CREATOR, CREATOR)), layer))
      .toMatchObject({ ok: false, refusal: { status: 400, error: "vm_chat_grant_creator" } });
    expect(await run(grantVmChat(shareInput(CREATOR, "")), layer))
      .toMatchObject({ ok: false, refusal: { status: 400, error: "invalid_request" } });
    expect(await run(grantVmChat(shareInput(CREATOR, ` ${MEMBER}`)), layer))
      .toMatchObject({ ok: false, refusal: { status: 400, error: "invalid_request" } });
    expect(grants.size).toBe(0);
  });

  test("a personal-account machine is never shared", async () => {
    const { grants, layer } = store(personalVm);
    const personal = { ...shareInput(CREATOR, MEMBER), billingTeamId: CREATOR, teamIds: [] };
    expect(await run(grantVmChat(personal), layer))
      .toMatchObject({ ok: false, refusal: { status: 409, error: "vm_chat_grants_personal_machine" } });
    expect(await run(listVmChatGrants(personal), layer)).toEqual({ ok: true, value: [] });
    expect(await run(revokeVmChat(personal), layer)).toEqual({ ok: true, value: { revoked: false } });
    expect(grants.size).toBe(0);
  });

  test("an unread member list or admin bit refuses with a retryable 503, never a grant", async () => {
    const { grants, layer } = store(teamVm);
    expect(await run(grantVmChat(shareInput(CREATOR, MEMBER, { teamDirectory: directory({ error: new Error("stack down") }) })), layer))
      .toMatchObject({ ok: false, refusal: { status: 503, error: "vm_chat_grants_unavailable" } });
    const broken: VmTeamAdminCheck = async () => { throw new Error("stack down"); };
    expect(await run(grantVmChat(shareInput(ADMIN, MEMBER, { isTeamAdmin: broken })), layer))
      .toMatchObject({ ok: false, refusal: { status: 503 } });
    expect(grants.size).toBe(0);
  });

  test("an admin check that never answers times out to 503", async () => {
    const { layer } = store(teamVm);
    const never: VmTeamAdminCheck = () => new Promise<never>(() => {});
    expect(await run(grantVmChat(shareInput(ADMIN, MEMBER, { isTeamAdmin: never })), layer))
      .toMatchObject({ ok: false, refusal: { status: 503 } });
  }, 10_000);

  test("the creator is never asked about admin", async () => {
    const { layer } = store(teamVm);
    const asked: string[] = [];
    const isTeamAdmin: VmTeamAdminCheck = async (_teamId, userId) => { asked.push(userId); return false; };
    expect(await run(grantVmChat(shareInput(CREATOR, MEMBER, { isTeamAdmin })), layer)).toMatchObject({ ok: true });
    expect(asked).toEqual([]);
  });

  test("a store without grant support answers 503", async () => {
    const { layer } = store(teamVm, { noGrantMethods: true });
    expect(await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer)).toMatchObject({ ok: false, refusal: { status: 503 } });
    expect(await run(listVmChatGrants(shareInput(CREATOR, "")), layer)).toMatchObject({ ok: false, refusal: { status: 503 } });
  });
});

describe("revoking a chat share", () => {
  test("the creator or an admin takes it back in one call; it is idempotent", async () => {
    const { grants, layer } = store(teamVm);
    await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer);
    expect(await run(revokeVmChat(shareInput(ADMIN, MEMBER)), layer)).toEqual({ ok: true, value: { revoked: true } });
    expect(grants.size).toBe(0);
    expect(await run(revokeVmChat(shareInput(CREATOR, MEMBER)), layer)).toEqual({ ok: true, value: { revoked: false } });
  });

  test("a plain member cannot revoke, even their own grant", async () => {
    const { grants, layer } = store(teamVm);
    await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer);
    expect(await run(revokeVmChat(shareInput(MEMBER, MEMBER)), layer))
      .toMatchObject({ ok: false, refusal: { status: 403 } });
    expect(grants.size).toBe(1);
  });

  test("a grant for someone who has since left the team can still be revoked", async () => {
    const { grants, layer } = store(teamVm);
    await run(grantVmChat(shareInput(CREATOR, MEMBER)), layer);
    const left = directory({ members: [CREATOR, ADMIN] });
    expect(await run(revokeVmChat(shareInput(CREATOR, MEMBER, { teamDirectory: left })), layer))
      .toEqual({ ok: true, value: { revoked: true } });
    expect(grants.size).toBe(0);
  });
});
