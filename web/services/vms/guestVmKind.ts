// Records a new Cloud machine's kind in its /etc/cmux/vm-kind at create.
//
// The record is informational: it says which kind cmux assigned the machine
// at create (`owner` or `team`), and nothing trusts it as a boundary (the
// guest's work user has passwordless sudo, so any process on the machine can
// change it; acpmux's remote sandbox no longer reads it). acpmux reads it for
// the vmHost default (cmux-tui acpmux hub/vm_host.rs), and the app's
// "Dedicated agent machine" switch shows only when it says `owner`. Two
// guest-side writers exist (the devbox image's cmux-vm-kind-sync, which asks
// /api/vm/reflection/kind, and cmux-host's record_owner_kind at a machine
// bind), but the devbox image New Machine boots may predate both, so nothing
// on it writes the file. This writes it from the backend, over the provider's
// exec, right after create.
//
// - The kind comes from the row's durable billing scope: `owner` when
//   owner_team_id is the creator's user id (vmKind.ts vmIsOnPersonalAccount),
//   `team` for every real team, even one whose only member is the creator
//   (membership is not a revocation receipt, so the create never writes
//   `owner` from it). A row with no billing owner gets nothing.
// - Only when no record exists (a symlink or a directory under that name
//   counts as one), so whatever wrote first stands. An image whose sync runs
//   bakes `team` and corrects it itself, so on it this does nothing.
// - Idempotent: a second run finds the file and leaves it.
// - Every attempt first reads the machine's row again and goes on only while
//   it is the same running machine (same row, provider id, owner and kind);
//   a deleted, paused or rebound machine ends the work with no exec.
// - After the create response, retried with a bounded backoff until the
//   machine's exec answers, for at most GUEST_VM_KIND_BUDGET in all (the
//   budget also aborts a provider request in flight); a failure is logged and
//   never fails the create.
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";

import { shellQuote } from "./drivers/cmuxTuiDaemon";
import type { VmProviderGatewayShape } from "./providerGateway";
import type { CloudVmRow, VmRepositoryShape } from "./repository";
import { vmIsOnPersonalAccount, type VmGuestKind } from "./vmKind";

/** The guest directory that holds the marker (root-owned on every image). */
export const GUEST_VM_KIND_DIRECTORY = "/etc/cmux";

/**
 * Writes `kind` to `<directory>/vm-kind` when no file of that name exists.
 *
 * Housekeeping, not protection: the write is a hard link (`ln -T`, GNU
 * coreutils on every cmux Linux guest) of a finished 0644 temporary file, so a
 * reader never sees a partial file, a record that appeared meanwhile is kept
 * (link() never replaces), and a directory that appeared there is not written
 * into. `written` is printed only after the path reads back as a regular file
 * holding `kind`. The temporary file is removed on every exit the shell sees,
 * and one an earlier killed run left behind (older than a minute, so never a
 * live writer's, the image's sync included) is swept first, on every run.
 * Prints `written` or `kept`; any other end is a non-zero exit. Run as root on
 * a guest, where /etc/cmux is root-owned.
 */
export function guestVmKindCommand(kind: VmGuestKind, directory = GUEST_VM_KIND_DIRECTORY): string {
  if (kind !== "owner" && kind !== "team") throw new Error(`unknown vm kind ${String(kind)}`);
  const dir = shellQuote(directory);
  return [
    `f=${shellQuote(`${directory}/vm-kind`)}`,
    `tmp=`,
    `trap 'rm -f "$tmp"' EXIT`,
    `trap 'exit 1' HUP INT TERM`,
    `[ -d ${dir} ] && find ${dir} -maxdepth 1 -type f -name '.vm-kind.*' -mmin +1 -exec rm -f {} + 2>/dev/null`,
    `if [ -e "$f" ] || [ -L "$f" ]; then echo kept; exit 0; fi`,
    `[ -d ${dir} ] || mkdir -p -m 0755 ${dir} || exit 1`,
    `tmp=$(mktemp ${shellQuote(`${directory}/.vm-kind.XXXXXX`)}) || exit 1`,
    `printf '${kind}\\n' > "$tmp" && chmod 0644 "$tmp" || exit 1`,
    `if ln -T "$tmp" "$f" 2>/dev/null; then`,
    `  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c 16 "$f")" = ${kind} ] || exit 1`,
    `  echo written; exit 0`,
    `fi`,
    `if [ -e "$f" ] || [ -L "$f" ]; then echo kept; exit 0; fi`,
    `exit 1`,
  ].join("\n");
}

type GuestVmKindRow = Pick<CloudVmRow, "provider" | "providerVmId" | "status" | "userId" | "ownerTeamId">;

/** The kind to record on this machine's guest, or null when the create records none. */
export function guestVmKindToRecord(row: GuestVmKindRow): VmGuestKind | null {
  // Only the cmux devbox image (Freestyle) reads the marker this way; GCP Labs
  // machines keep their own bootstrap and stay off until it writes one.
  if (row.provider !== "freestyle" || !row.providerVmId || row.status !== "running") return null;
  if (vmIsOnPersonalAccount(row)) return "owner";
  return row.ownerTeamId.trim() ? "team" : null;
}

/** Whether `current` is still the machine `created` was, with the same kind to record. */
export function sameGuestVmKindTarget(created: CloudVmRow, current: CloudVmRow | null, kind: VmGuestKind): boolean {
  return !!current
    && current.id === created.id
    && current.provider === created.provider
    && current.providerVmId === created.providerVmId
    && current.userId === created.userId
    && current.ownerTeamId === created.ownerTeamId
    && guestVmKindToRecord(current) === kind;
}

/** All of the work, exec time included, ends within this. */
export const GUEST_VM_KIND_BUDGET = Duration.minutes(2);

/**
 * 1, 2, 4, 8 s, then every 10 s, at most 12 retries: 13 tries over 95 s of
 * waits. Slow execs (10 s each at most) are cut off by GUEST_VM_KIND_BUDGET.
 */
export const GUEST_VM_KIND_RETRY: Schedule.Schedule<unknown> = Schedule.exponential("1 second").pipe(
  Schedule.modifyDelay((delay) => Duration.min(delay, Duration.seconds(10))),
  Schedule.intersect(Schedule.recurs(12)),
);

/** The machine is gone or is no longer the one this work was for: stop, never retry. */
class GuestVmKindTargetGone {
  readonly _tag = "GuestVmKindTargetGone";
}

/**
 * Records the machine's kind (module docs) after the create response when the
 * route gives a hook, detached otherwise. Never fails.
 */
export function scheduleGuestVmKindRecord(
  repo: Pick<VmRepositoryShape, "findUserVm">,
  providers: VmProviderGatewayShape,
  row: CloudVmRow,
  defer: ((work: Effect.Effect<void>) => void) | undefined,
  retry: Schedule.Schedule<unknown> = GUEST_VM_KIND_RETRY,
): Effect.Effect<void> {
  const providerVmId = row.providerVmId;
  const kind = guestVmKindToRecord(row);
  if (!providerVmId || !kind) return Effect.void;
  const command = guestVmKindCommand(kind);
  const attempt = Effect.gen(function* () {
    // A failed read is retried; only a confirmed same machine gets the exec.
    const current = yield* Effect.suspend(() =>
      repo.findUserVm({ userId: row.userId, billingTeamId: row.ownerTeamId, providerVmId, provider: row.provider })
    );
    if (!sameGuestVmKindTarget(row, current, kind)) return yield* Effect.fail(new GuestVmKindTargetGone());
    const result = yield* Effect.suspend(() =>
      providers.exec(row.provider, providerVmId, command, {
        timeoutMs: 10_000,
        providerMetadata: row.providerMetadata,
        // /etc/cmux is root-owned.
        asRoot: true,
        // The budget below ends the provider request too, not only the wait.
        cancelOnInterrupt: true,
      })
    );
    // The command exits 0 only after `written` or `kept`; anything else (a
    // silent or timed-out exec included) is tried again.
    if (result.exitCode !== 0) return yield* Effect.fail(new Error(`vm-kind write exited ${result.exitCode}`));
    return result.stdout.trim().split("\n").at(-1) ?? "";
  });
  const work = attempt.pipe(
    Effect.retry({ schedule: retry, while: (error) => !(error instanceof GuestVmKindTargetGone) }),
    Effect.timeoutFail({ duration: GUEST_VM_KIND_BUDGET, onTimeout: () => new Error("vm-kind write ran out of time") }),
    Effect.flatMap((outcome) => Effect.logDebug("Cloud vm-kind marker", { vmId: row.id, kind, outcome })),
    Effect.catchAllCause((cause) => Effect.logWarning("Cloud vm-kind marker not written", { vmId: row.id, kind, cause })),
  );
  if (defer) {
    defer(work);
    return Effect.void;
  }
  return Effect.asVoid(Effect.forkDaemon(work));
}
