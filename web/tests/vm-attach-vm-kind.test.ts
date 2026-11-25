// attach-endpoint's `vmKind`: the Mac app gives up its local sandbox for its
// own session only when this reads "owner", so "owner" must mean a machine the
// signed-in caller created: their personal account, or a Stack team whose
// member list, read for this attach, still contains them, whatever its size.
import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import type { VmTeamDirectory } from "../services/vms/teamDirectory";
import { vmKindForCaller, vmKindForCallerNeedsMembers } from "../services/vms/vmKind";
import { openAttachEndpoint, openVmCmuxRemote } from "../services/vms/workflows";

const NOW = new Date("2026-01-01T00:00:00.000Z");
const CREATOR = "user-creator";
const MEMBER = "user-member";
const TEAM = "team-shared";

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000501",
    userId: CREATOR,
    billingTeamId: CREATOR,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "vm-kind",
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
    ownerTeamId: CREATOR,
    coderouterPoolId: null,
    ...overrides,
  };
}

const personalVm = row();
const teamVm = row({ billingTeamId: TEAM, ownerTeamId: TEAM });

// The repository answers with `vm` whoever asks: the account scoping is
// findUserVm's job, so these tests cover what the kind says once a caller
// has been let in.
function layerFor(vm: CloudVmRow) {
  const repo = {
    findUserVm: () => Effect.succeed(vm),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    recordLease: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    upsertVmSession: () => Effect.succeed(null),
    legacyResourceReservationCandidates: () => Effect.succeed([]),
  } as unknown as VmRepositoryShape;
  const providers = {
    getStatus: () => Effect.succeed("running"),
    getStats: () => Effect.succeed({ cpus: 4, memoryTotalMb: 8192, diskTotalMb: 32768 }),
    openCmuxRemote: () => Effect.succeed({
      transport: "cmux-remote", route: "ws://10.0.0.5:1337/v1/link", token: "test-token",
      session: "test-session", expiresAtUnix: 2_000_000_000, trustedCarrier: true,
    }),
    openAttach: () => Effect.succeed({
      transport: "websocket", url: "wss://vm.test/attach", headers: {}, token: "test-token",
      sessionId: "test-session", attachmentId: "test-attachment", expiresAtUnix: 2_000_000_000,
    }),
  } as unknown as VmProviderGatewayShape;
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

// A Stack directory that answers `members` for every team (null: no such
// team), or throws `error`, and records which teams it was asked about.
function directory(answer: { members?: readonly string[] | null; error?: Error; never?: true }) {
  const asked: string[] = [];
  const teamDirectory: VmTeamDirectory = {
    async listMemberIds(teamId) {
      asked.push(teamId);
      if (answer.never) return new Promise<never>(() => {});
      if (answer.error) throw answer.error;
      return answer.members ?? null;
    },
  };
  return { teamDirectory, asked };
}

function access(userId: string, billingTeamId: string, teamDirectory?: VmTeamDirectory) {
  return { userId, billingTeamId, teamIds: [billingTeamId], providerVmId: "vm-kind", callerPlanId: "pro", teamDirectory };
}

async function cmuxRemoteKind(vm: CloudVmRow, userId: string, billingTeamId: string, teamDirectory?: VmTeamDirectory) {
  const endpoint = await Effect.runPromise(openVmCmuxRemote(access(userId, billingTeamId, teamDirectory)).pipe(Effect.provide(layerFor(vm))));
  expect(endpoint.token).toBe("test-token");
  return endpoint.vmKind;
}

async function websocketKind(vm: CloudVmRow, userId: string, billingTeamId: string, teamDirectory?: VmTeamDirectory) {
  const endpoint = await Effect.runPromise(openAttachEndpoint(access(userId, billingTeamId, teamDirectory)).pipe(Effect.provide(layerFor(vm))));
  expect(endpoint.transport).toBe("websocket");
  return endpoint.vmKind;
}

describe("attach-endpoint vmKind", () => {
  test("the creator attaching to their own personal machine gets owner", async () => {
    expect(await cmuxRemoteKind(personalVm, CREATOR, CREATOR)).toBe("owner");
    expect(await websocketKind(personalVm, CREATOR, CREATOR)).toBe("owner");
  });

  test("a team machine with no membership answer is team, for its creator too", async () => {
    expect(await cmuxRemoteKind(teamVm, CREATOR, TEAM)).toBe("team");
    expect(await websocketKind(teamVm, CREATOR, TEAM)).toBe("team");
  });

  test("another account that can attach never gets owner", async () => {
    // A team member attaching to a teammate's machine.
    expect(await cmuxRemoteKind(teamVm, MEMBER, TEAM)).toBe("team");
    expect(await websocketKind(teamVm, MEMBER, TEAM)).toBe("team");
    // Even if a personal machine were ever handed to someone other than its
    // creator, that caller is not its owner.
    expect(await cmuxRemoteKind(personalVm, MEMBER, CREATOR)).toBe("team");
    expect(await websocketKind(personalVm, MEMBER, CREATOR)).toBe("team");
    // A creator id that differs from the caller only by padding is not the caller.
    const padded = row({ userId: ` ${CREATOR} ` });
    expect(await cmuxRemoteKind(padded, CREATOR, CREATOR)).toBe("team");
    expect(await websocketKind(padded, CREATOR, CREATOR)).toBe("team");
  });

  const soloTeamVm = row({ billingTeamId: "team-solo", ownerTeamId: "team-solo" });

  test("the creator's machine on a team whose only member is them is owner", async () => {
    const solo = directory({ members: [CREATOR] });
    expect(await cmuxRemoteKind(soloTeamVm, CREATOR, "team-solo", solo.teamDirectory)).toBe("owner");
    expect(await websocketKind(soloTeamVm, CREATOR, "team-solo", solo.teamDirectory)).toBe("owner");
    // The list is read for each attach, for the machine's own team.
    expect(solo.asked).toEqual(["team-solo", "team-solo"]);
  });

  test("the creator stays owner when their team grows to three members", async () => {
    const answer: { members: readonly string[] } = { members: [CREATOR] };
    const { teamDirectory } = directory(answer);
    expect(await cmuxRemoteKind(teamVm, CREATOR, TEAM, teamDirectory)).toBe("owner");
    answer.members = [CREATOR, MEMBER, "user-third"];
    expect(await cmuxRemoteKind(teamVm, CREATOR, TEAM, teamDirectory)).toBe("owner");
    expect(await websocketKind(teamVm, CREATOR, TEAM, teamDirectory)).toBe("owner");
    expect(await websocketKind(teamVm, CREATOR, TEAM, directory({ members: [MEMBER, CREATOR] }).teamDirectory)).toBe("owner");
    expect(await cmuxRemoteKind(teamVm, MEMBER, TEAM, teamDirectory)).toBe("team");
    expect(await websocketKind(teamVm, MEMBER, TEAM, teamDirectory)).toBe("team");
    answer.members = [MEMBER, "user-third"];
    expect(await cmuxRemoteKind(teamVm, CREATOR, TEAM, teamDirectory)).toBe("team");
    expect(await websocketKind(teamVm, CREATOR, TEAM, teamDirectory)).toBe("team");
  });

  test("a teammate on the creator's one-member team is never owner, and Stack is not asked", async () => {
    // A machine the caller did not create, on a team whose only member is the caller.
    const creatorLeft = row({ userId: MEMBER, billingTeamId: "team-solo", ownerTeamId: "team-solo" });
    const solo = directory({ members: [CREATOR] });
    expect(await cmuxRemoteKind(creatorLeft, CREATOR, "team-solo", solo.teamDirectory)).toBe("team");
    expect(await websocketKind(creatorLeft, CREATOR, "team-solo", solo.teamDirectory)).toBe("team");
    expect(solo.asked).toEqual([]);
  });

  test("an unread, failed, missing or timed-out member list is team, never owner", async () => {
    // No directory: the list is unknown.
    expect(await cmuxRemoteKind(soloTeamVm, CREATOR, "team-solo")).toBe("team");
    expect(await websocketKind(soloTeamVm, CREATOR, "team-solo")).toBe("team");
    expect(await cmuxRemoteKind(soloTeamVm, CREATOR, "team-solo", directory({ error: new Error("stack down") }).teamDirectory)).toBe("team");
    expect(await websocketKind(soloTeamVm, CREATOR, "team-solo", directory({ members: null }).teamDirectory)).toBe("team");
    expect(await websocketKind(soloTeamVm, CREATOR, "team-solo", directory({ members: [] }).teamDirectory)).toBe("team");
  });

  test("a member list that never answers times out to team", async () => {
    expect(await cmuxRemoteKind(soloTeamVm, CREATOR, "team-solo", directory({ never: true }).teamDirectory)).toBe("team");
  }, 10_000);

  test("the personal machine never asks Stack", async () => {
    const solo = directory({ members: [MEMBER] });
    expect(await cmuxRemoteKind(personalVm, CREATOR, CREATOR, solo.teamDirectory)).toBe("owner");
    expect(solo.asked).toEqual([]);
  });

  test("a machine with no usable billing owner is never answered as owner", async () => {
    // The access check refuses it before any endpoint (and any kind) is made;
    // vmKindForCaller's own null for it is covered below.
    const ownerless = row({ ownerTeamId: "  " });
    const remote = await Effect.runPromise(
      openVmCmuxRemote(access(CREATOR, CREATOR)).pipe(Effect.either, Effect.provide(layerFor(ownerless))),
    );
    expect(remote).toMatchObject({ _tag: "Left", left: { _tag: "VmNotFoundError" } });
    const websocket = await Effect.runPromise(
      openAttachEndpoint(access(CREATOR, CREATOR)).pipe(Effect.either, Effect.provide(layerFor(ownerless))),
    );
    expect(websocket).toMatchObject({ _tag: "Left", left: { _tag: "VmNotFoundError" } });
  });
});

describe("vmKindForCaller", () => {
  test("owner only for the caller's own personal machine", () => {
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: CREATOR }, CREATOR)).toBe("owner");
  });

  test("anyone else, an unread team, and a blank caller get team", () => {
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: CREATOR }, MEMBER)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: TEAM }, CREATOR)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: TEAM }, MEMBER)).toBe("team");
    // The caller's id equal to the team's id is still not a personal machine
    // (the caller did not create it).
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: TEAM }, TEAM)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: CREATOR }, "")).toBe("team");
    expect(vmKindForCaller({ userId: "", ownerTeamId: CREATOR }, CREATOR)).toBe("team");
    // Ids compare exactly: padding never makes someone the owner.
    expect(vmKindForCaller({ userId: ` ${CREATOR} `, ownerTeamId: CREATOR }, CREATOR)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: ` ${CREATOR}` }, CREATOR)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: CREATOR }, ` ${CREATOR}`)).toBe("team");
  });

  test("no usable billing owner is null", () => {
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: "" }, CREATOR)).toBeNull();
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: " " }, CREATOR)).toBeNull();
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: "" }, CREATOR, { memberIds: [CREATOR] })).toBeNull();
  });

  test("a team machine is owner only for its creator on the member list, at any team size", () => {
    const solo = { userId: CREATOR, ownerTeamId: TEAM };
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [CREATOR] })).toBe("owner");
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [CREATOR, MEMBER, "user-third"] })).toBe("owner");
    expect(vmKindForCaller(solo, MEMBER, { memberIds: [CREATOR, MEMBER, "user-third"] })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [CREATOR, CREATOR] })).toBe("owner");
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [MEMBER, "user-third"] })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [] })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR, { memberIds: null })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR, { error: "error" })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR, { error: "timeout" })).toBe("team");
    expect(vmKindForCaller(solo, CREATOR)).toBe("team");
    // Not the creator: team, whatever the list says.
    expect(vmKindForCaller({ userId: MEMBER, ownerTeamId: TEAM }, CREATOR, { memberIds: [CREATOR] })).toBe("team");
    expect(vmKindForCaller(solo, "", { memberIds: [""] })).toBe("team");
    // Exact ids in the list too.
    expect(vmKindForCaller(solo, CREATOR, { memberIds: [` ${CREATOR}`] })).toBe("team");
  });

  test("only a machine the caller created on a Stack team needs the member list", () => {
    expect(vmKindForCallerNeedsMembers({ userId: CREATOR, ownerTeamId: TEAM }, CREATOR)).toBe(true);
    expect(vmKindForCallerNeedsMembers({ userId: CREATOR, ownerTeamId: CREATOR }, CREATOR)).toBe(false);
    expect(vmKindForCallerNeedsMembers({ userId: MEMBER, ownerTeamId: TEAM }, CREATOR)).toBe(false);
    expect(vmKindForCallerNeedsMembers({ userId: CREATOR, ownerTeamId: " " }, CREATOR)).toBe(false);
    expect(vmKindForCallerNeedsMembers({ userId: "", ownerTeamId: TEAM }, "")).toBe(false);
  });
});
