// attach-endpoint's `vmKind`: the Mac app gives up its local sandbox for its
// own session only when this reads "owner", so "owner" must mean the signed-in
// caller's own personal machine and nothing else.
import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { vmKindForCaller } from "../services/vms/vmKind";
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

function access(userId: string, billingTeamId: string) {
  return { userId, billingTeamId, teamIds: [billingTeamId], providerVmId: "vm-kind", callerPlanId: "pro" };
}

async function cmuxRemoteKind(vm: CloudVmRow, userId: string, billingTeamId: string) {
  const endpoint = await Effect.runPromise(openVmCmuxRemote(access(userId, billingTeamId)).pipe(Effect.provide(layerFor(vm))));
  expect(endpoint.token).toBe("test-token");
  return endpoint.vmKind;
}

async function websocketKind(vm: CloudVmRow, userId: string, billingTeamId: string) {
  const endpoint = await Effect.runPromise(openAttachEndpoint(access(userId, billingTeamId)).pipe(Effect.provide(layerFor(vm))));
  expect(endpoint.transport).toBe("websocket");
  return endpoint.vmKind;
}

describe("attach-endpoint vmKind", () => {
  test("the creator attaching to their own personal machine gets owner", async () => {
    expect(await cmuxRemoteKind(personalVm, CREATOR, CREATOR)).toBe("owner");
    expect(await websocketKind(personalVm, CREATOR, CREATOR)).toBe("owner");
  });

  test("a team machine is team, for its creator too", async () => {
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

  test("a team whose only member is the creator is still team", async () => {
    const soloTeamVm = row({ billingTeamId: "team-solo", ownerTeamId: "team-solo" });
    expect(await cmuxRemoteKind(soloTeamVm, CREATOR, "team-solo")).toBe("team");
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

  test("anyone else, any team, and a blank caller get team", () => {
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: CREATOR }, MEMBER)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: TEAM }, CREATOR)).toBe("team");
    expect(vmKindForCaller({ userId: CREATOR, ownerTeamId: TEAM }, MEMBER)).toBe("team");
    // The caller's id equal to the team's id is still not a personal machine.
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
  });
});
