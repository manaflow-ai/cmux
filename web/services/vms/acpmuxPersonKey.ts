import * as Effect from "effect/Effect";
import {
  ACPMUX_EXIT_TEAM_VM,
  ACPMUX_EXIT_UNSUPPORTED,
  ACPMUX_PREPARE_TIMEOUT_MS,
  ACPMUX_STDIN_EXEC_TIMEOUT_MS,
  acpmuxKeyedStartCommand,
  acpmuxPersonHoldsCommand,
  acpmuxPersonHoldsFrames,
  acpmuxPrepareCommand,
  redactGuestLine,
} from "./drivers/acpmuxPersonKey";
import { SecretBytes, type ExecResult, type ProviderId } from "./drivers/types";
import { VmProviderGateway } from "./providerGateway";
import { listTeamMemberIdsWithTimeout, type VmTeamDirectory } from "./teamDirectory";
import type { CloudVmRow } from "./repository";
import { requireAccessibleUserVm, type ExistingVmAccessInput } from "./workflows";

// cx-0q7o slice 2d (cx-psxg): the keyed acpmux start and the person_holds
// check on a Cloud machine, for the two app routes under
// app/api/vm/[id]/acpmux. The backend and the provider are trusted for key
// delivery (#13742 D16 update 4); the threat is agents on the machine.
//
// Only the machine's single owner may do either (hq-84 rule): a key bound
// on a teammate's machine would let its holder allow that teammate's agent
// prompts. Single owner = the caller created the machine, and its owner
// scope is the caller alone (the caller's own id, or a team whose only
// member is the caller); a team machine marker on the guest refuses too.
//
// No failure here carries a provider error, the command, its stdin or the
// guest's raw output: an outcome is a code, plus for a failed start the
// last stderr line with every long hex or base64 run removed.

export type AcpmuxRefusal =
  | "not_single_owner"
  | "owner_unconfirmed"
  | "team_vm"
  | "not_running"
  | "unsupported"
  | "timeout"
  | "start_failed"
  | "holds_failed"
  | "provider_failed";

export type AcpmuxOutcome<A> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly refusal: AcpmuxRefusal; readonly line?: string };

export type AcpmuxPersonKeyInput = ExistingVmAccessInput & {
  readonly teamDirectory: VmTeamDirectory;
};

const refuse = <A>(refusal: AcpmuxRefusal, line?: string): AcpmuxOutcome<A> => ({ ok: false, refusal, ...(line ? { line } : {}) });

type OwnedVm = { readonly vm: CloudVmRow } | { readonly refusal: AcpmuxRefusal };
const refused = (refusal: AcpmuxRefusal): OwnedVm => ({ refusal });

/** The machine, when the caller is its single owner and it is running; else the refusal. */
function requireSingleOwnerRunningVm(input: AcpmuxPersonKeyInput) {
  return Effect.gen(function* () {
    const vm = yield* requireAccessibleUserVm(input);
    if (vm.userId !== input.userId) return refused("not_single_owner");
    const scope = vm.ownerTeamId.trim();
    if (scope !== input.userId) {
      const lookup = yield* listTeamMemberIdsWithTimeout(input.teamDirectory, scope);
      if ("error" in lookup) return refused("owner_unconfirmed");
      const members = lookup.memberIds;
      if (!members || members.length !== 1 || members[0] !== input.userId) return refused("not_single_owner");
    }
    if (vm.status !== "running") return refused("not_running");
    const owned: OwnedVm = { vm };
    return owned;
  });
}

/** One provider exec; a provider failure is only a code (its cause is dropped, never logged). */
function guestExec(provider: ProviderId, vmId: string, command: string, timeoutMs: number, stdin?: SecretBytes) {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    return yield* providers.exec(provider, vmId, command, { timeoutMs, ...(stdin ? { stdin } : {}) }).pipe(
      Effect.map((result): ExecResult | null => result),
      Effect.catchAll(() => Effect.succeed(null)),
    );
  });
}

function commonRefusal(result: ExecResult): AcpmuxRefusal | null {
  if (result.exitCode === ACPMUX_EXIT_TEAM_VM) return "team_vm";
  if (result.exitCode === 124) return "timeout";
  return null;
}

/**
 * Restarts the machine's acpmux with the caller's key `keyLine` (64 hex and
 * a newline, checked by the route). The key goes only to the second exec's
 * stdin; `keyLine` is zeroed before this returns, whatever happens.
 */
export function acpmuxKeyedStartVm(input: AcpmuxPersonKeyInput & { readonly keyLine: Uint8Array }) {
  const key = new SecretBytes(input.keyLine);
  return Effect.gen(function* () {
    const owned = yield* requireSingleOwnerRunningVm(input);
    if ("refusal" in owned) return refuse<{ personInstance: string }>(owned.refusal);
    const { vm } = owned;
    const provider = vm.provider;
    const prepared = yield* guestExec(provider, input.providerVmId, acpmuxPrepareCommand(), ACPMUX_PREPARE_TIMEOUT_MS);
    if (!prepared) return refuse<{ personInstance: string }>("provider_failed");
    const preparedRefusal = commonRefusal(prepared);
    if (preparedRefusal) return refuse<{ personInstance: string }>(preparedRefusal);
    if (prepared.exitCode === ACPMUX_EXIT_UNSUPPORTED) return refuse<{ personInstance: string }>("unsupported");
    if (prepared.exitCode !== 0) return refuse<{ personInstance: string }>("start_failed", redactGuestLine(prepared.stderr));

    const started = yield* guestExec(provider, input.providerVmId, acpmuxKeyedStartCommand(), ACPMUX_STDIN_EXEC_TIMEOUT_MS, key);
    key.wipe();
    if (!started) return refuse<{ personInstance: string }>("provider_failed");
    const startedRefusal = commonRefusal(started);
    if (startedRefusal) return refuse<{ personInstance: string }>(startedRefusal);
    // `acp --json` prints the status object pretty (cli/output.rs print_json): parse all of stdout.
    const status = parseJsonObject(started.stdout.trim());
    const instance = status?.personInstance;
    if (started.exitCode !== 0 || status?.personKey !== true || typeof instance !== "string" || instance.length === 0 || instance.length > 256) {
      return refuse<{ personInstance: string }>("start_failed", redactGuestLine(started.stderr));
    }
    return { ok: true as const, value: { personInstance: instance } };
  }).pipe(Effect.ensuring(Effect.sync(() => key.wipe())));
}

/** `_acpmux/person_holds {nonce}` on the machine's acpmux; the app checks the proof. */
export function acpmuxPersonHoldsVm(input: AcpmuxPersonKeyInput & { readonly nonce: string }) {
  return Effect.gen(function* () {
    const owned = yield* requireSingleOwnerRunningVm(input);
    if ("refusal" in owned) return refuse<{ instance: string; proof: string }>(owned.refusal);
    const frames = new SecretBytes(new Uint8Array(Buffer.from(acpmuxPersonHoldsFrames(input.nonce), "utf8")));
    const held = yield* guestExec(owned.vm.provider, input.providerVmId, acpmuxPersonHoldsCommand(), ACPMUX_STDIN_EXEC_TIMEOUT_MS, frames);
    if (!held) return refuse<{ instance: string; proof: string }>("provider_failed");
    const heldRefusal = commonRefusal(held);
    if (heldRefusal) return refuse<{ instance: string; proof: string }>(heldRefusal);
    const answer = held.stdout.split("\n").map(parseJsonObject).find((frame) => frame?.id === 2);
    const result = answer?.result as Record<string, unknown> | undefined;
    const instance = result?.instance, proof = result?.proof;
    if (typeof instance !== "string" || typeof proof !== "string" || !/^[0-9a-f]{64}$/.test(proof)) {
      return refuse<{ instance: string; proof: string }>("holds_failed");
    }
    return { ok: true as const, value: { instance, proof } };
  });
}

function parseJsonObject(line: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(line);
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
  } catch {
    return null;
  }
}
