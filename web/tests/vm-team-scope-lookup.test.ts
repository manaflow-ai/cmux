import { describe, expect, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { requireUserVm } from "../services/vms/workflows";

// A machine id names one machine. The request's X-Cmux-Team-Id is only the scope the
// client had selected; a stale or guessed team (restored pane, team switch, personal
// machine read with a team selected) must not turn a reachable machine into 404 vm_not_found.

const row = (ownerTeamId: string): CloudVmRow => ({
  id: "row-1", userId: "user-1", billingTeamId: ownerTeamId, ownerTeamId, coderouterPoolId: null, billingPlanId: "pro",
  provider: "freestyle", providerVmId: "vm-1", displayName: null, slug: "brave-otter", imageId: "sh-devbox", imageVersion: null,
  status: "running", idempotencyKey: null, createdAt: new Date(0), updatedAt: new Date(0), destroyedAt: null, failureCode: null,
  failureMessage: null, providerMetadata: {},
}) as CloudVmRow;

function layerFor(ownerTeamId: string) {
  const repo = {
    findUserVm: (input: { userId: string; billingTeamId?: string | null; providerVmId: string }) =>
      Effect.succeed((input.billingTeamId?.trim() || input.userId) === ownerTeamId && input.providerVmId === "vm-1" ? row(ownerTeamId) : null),
  } as unknown as VmRepositoryShape;
  return Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape));
}

async function lookup(ownerTeamId: string, caller: { billingTeamId: string; teamIds: string[] }) {
  const exit = await Effect.runPromiseExit(
    requireUserVm({ userId: "user-1", providerVmId: "vm-1", ...caller }).pipe(Effect.provide(layerFor(ownerTeamId))) as Effect.Effect<CloudVmRow, unknown>,
  );
  if (Exit.isSuccess(exit)) return exit.value.ownerTeamId;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? (failure.value as { _tag?: string })._tag : "die";
}

describe("requireUserVm team scope", () => {
  test("finds the machine in the requested team", async () => {
    expect(await lookup("team-a", { billingTeamId: "team-a", teamIds: ["team-a", "team-b"] })).toBe("team-a");
  });
  test("a stale team header still finds a machine of another team the caller belongs to", async () => {
    expect(await lookup("team-b", { billingTeamId: "team-a", teamIds: ["team-a", "team-b"] })).toBe("team-b");
  });
  test("a personal machine is found while a team is selected", async () => {
    expect(await lookup("user-1", { billingTeamId: "team-a", teamIds: ["team-a"] })).toBe("user-1");
  });
  test("a machine of a team the caller left stays vm_not_found", async () => {
    expect(await lookup("team-x", { billingTeamId: "team-a", teamIds: ["team-a"] })).toBe("VmNotFoundError");
  });
});
