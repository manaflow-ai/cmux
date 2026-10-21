import { enforceVmAllocationRateLimit } from "../vms/allocationRateLimit";
import { createRun } from "./repository";

export type RunAllocationAdmissionDependencies = {
  readonly check?: typeof enforceVmAllocationRateLimit;
  readonly persist?: typeof createRun;
};

/** Fail closed at the allocation boundary before a Run can reserve attempts. */
export async function createRunWithAllocationAdmission(
  input: {
    readonly request: Request;
    readonly billingTeamId: string;
    readonly run: Parameters<typeof createRun>[0];
  },
  dependencies: RunAllocationAdmissionDependencies = {},
) {
  const limited = await (dependencies.check ?? enforceVmAllocationRateLimit)({
    request: input.request,
    route: "run.create",
    billingTeamId: input.billingTeamId,
    cost: input.run.desiredAttempts,
  });
  if (limited) return { kind: "limited" as const, response: limited };
  return {
    kind: "created" as const,
    run: await (dependencies.persist ?? createRun)(input.run),
  };
}
