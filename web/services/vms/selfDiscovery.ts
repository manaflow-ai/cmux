// What a Cloud VM can learn about itself and its siblings from inside.
//
// The guest holds no Stack token, so `GET /api/vm/self` authenticates with the
// route token the Freestyle TLS edge injects (bound to one `cloud_vms` row).
// That identity carries the team, and this module turns the team's machine
// rows into the one contract the guest `cmux self` / `cmux vm ls` verbs print.
// Pure: no database or framework imports, so the route test and the guest CLI
// test share it.
import type { TeamMachine } from "../coderouter/teamMachines";

export const VM_SELF_SCHEMA = 1;

export type VmSelfMachine = {
  /** The provider machine id: the `id` every Mac `cmux vm …` verb takes. */
  readonly id: string;
  /** The `cloud_vms` row id the route token is bound to. */
  readonly vmId: string;
  /** displayName, else slug, else id: what a person calls the machine. */
  readonly name: string;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly status: string;
  readonly createdAt: string;
  /** True on the machine that made the request. */
  readonly self: boolean;
};

export type VmSelfResponse = {
  readonly schema: typeof VM_SELF_SCHEMA;
  readonly machine: VmSelfMachine;
  readonly team: { readonly id: string };
  /** Live machines in the team, newest first, the caller included. */
  readonly machines: readonly VmSelfMachine[];
};

/** The row facts one `VmSelfMachine` is built from; `TeamMachine` and the reflection row both satisfy it. */
export type VmSelfMachineSource = {
  readonly vmId: string;
  readonly providerVmId: string | null;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly status: string;
  /** ISO-8601. */
  readonly createdAt: string;
};

function machineName(machine: VmSelfMachineSource): string {
  return machine.displayName ?? machine.slug ?? machine.providerVmId ?? machine.vmId;
}

/**
 * One machine as the guest sees it. Null when the row has no provider id yet
 * (still provisioning): such a machine has no address a verb could take, so it
 * is hidden — the same filter the Mac's `cmux vm ls` applies. Shared with
 * reflection (services/vms/reflection.ts) so `cmux self` and `cmux vm ls` read
 * one shape whichever endpoint answers.
 */
export function vmSelfMachine(machine: VmSelfMachineSource, selfVmId: string): VmSelfMachine | null {
  if (!machine.providerVmId) return null;
  return {
    id: machine.providerVmId,
    vmId: machine.vmId,
    name: machineName(machine),
    displayName: machine.displayName,
    slug: machine.slug,
    status: machine.status,
    createdAt: machine.createdAt,
    self: machine.vmId === selfVmId,
  };
}

function selfMachine(machine: TeamMachine, selfVmId: string): VmSelfMachine | null {
  return vmSelfMachine(machine, selfVmId);
}

/**
 * The guest-facing view of a team's machines. `self` is the caller's own row,
 * looked up by id so a large team's list cap can never drop it; `owned` is
 * the team's live list. Destroyed rows and rows with no provider id are
 * hidden, the same filter the Mac's `cmux vm ls` applies. Returns null when
 * the caller's row is gone or destroyed (its token still in flight, or
 * mis-bound): the route answers 404.
 */
export function vmSelfResponse(
  identity: { readonly teamId: string; readonly vmId: string },
  self: TeamMachine | null,
  owned: readonly TeamMachine[],
): VmSelfResponse | null {
  if (!self || self.destroyed || self.vmId !== identity.vmId) return null;
  const machine = selfMachine(self, identity.vmId);
  if (!machine) return null;
  const siblings = owned
    .filter((entry) => !entry.destroyed && entry.vmId !== self.vmId)
    .map((entry) => selfMachine(entry, identity.vmId))
    .filter((entry): entry is VmSelfMachine => entry !== null);
  const machines = [...siblings, machine].sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
  return { schema: VM_SELF_SCHEMA, machine, team: { id: identity.teamId }, machines };
}
