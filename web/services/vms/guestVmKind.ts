// Records a new Cloud machine's kind in its /etc/cmux/vm-kind at create.
//
// The marker is the one thing on the machine that says whose VM it is: acpmux
// turns vmHost on by default only when it reads `owner` (cmux-tui acpmux
// hub/vm_host.rs), the app's "Dedicated agent machine" switch shows only then,
// and `team` keeps a shared machine's guest in team mode. Two guest-side
// writers exist (the devbox image's cmux-vm-kind-sync, which asks
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
// - Only when the file is absent: an existing marker is never replaced, and
//   neither is a symlink or a directory under that name. An image whose sync
//   runs writes `team` at bake and corrects it itself, so on it this does
//   nothing and the sync's answer stands.
// - Idempotent: a second run finds the file and leaves it.
// - After the create response, retried with a bounded backoff until the
//   machine's exec answers; a failure is logged and never fails the create.
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";

import { shellQuote } from "./drivers/cmuxTuiDaemon";
import type { VmProviderGatewayShape } from "./providerGateway";
import type { CloudVmRow } from "./repository";
import { vmIsOnPersonalAccount, type VmGuestKind } from "./vmKind";

/** The guest directory that holds the marker (root-owned on every image). */
export const GUEST_VM_KIND_DIRECTORY = "/etc/cmux";

/**
 * Writes `kind` to `<directory>/vm-kind` when no file of that name exists.
 * The write is a hard link of a finished 0644 temporary file, so a reader
 * never sees a partial file and a marker that appeared meanwhile is kept
 * (link() never replaces). Prints `written` or `kept`; any other end is a
 * non-zero exit. Run as root on a guest, so the file is root-owned.
 */
export function guestVmKindCommand(kind: VmGuestKind, directory = GUEST_VM_KIND_DIRECTORY): string {
  if (kind !== "owner" && kind !== "team") throw new Error(`unknown vm kind ${String(kind)}`);
  const dir = shellQuote(directory);
  return [
    `f=${shellQuote(`${directory}/vm-kind`)}`,
    `if [ -e "$f" ] || [ -L "$f" ]; then echo kept; exit 0; fi`,
    `[ -d ${dir} ] || mkdir -p -m 0755 ${dir} || exit 1`,
    `tmp=$(mktemp ${shellQuote(`${directory}/.vm-kind.XXXXXX`)}) || exit 1`,
    `printf '${kind}\\n' > "$tmp" && chmod 0644 "$tmp" && ln "$tmp" "$f" 2>/dev/null; linked=$?`,
    `rm -f "$tmp"`,
    `if [ "$linked" -eq 0 ]; then echo written; elif [ -e "$f" ] || [ -L "$f" ]; then echo kept; else exit 1; fi`,
  ].join("\n");
}

/** The kind to record on this machine's guest, or null when the create records none. */
export function guestVmKindToRecord(
  row: Pick<CloudVmRow, "provider" | "providerVmId" | "status" | "userId" | "ownerTeamId">,
): VmGuestKind | null {
  // Only the cmux devbox image (Freestyle) reads the marker this way; GCP Labs
  // machines keep their own bootstrap and stay off until it writes one.
  if (row.provider !== "freestyle" || !row.providerVmId || row.status !== "running") return null;
  if (vmIsOnPersonalAccount(row)) return "owner";
  return row.ownerTeamId.trim() ? "team" : null;
}

/**
 * Up to 13 tries over about two minutes: 1, 2, 4, 8 s, then every 15 s. A
 * machine's exec can lag its create answer by a few seconds.
 */
export const GUEST_VM_KIND_RETRY: Schedule.Schedule<unknown> = Schedule.exponential("1 second").pipe(
  Schedule.modifyDelay((delay) => Duration.min(delay, Duration.seconds(15))),
  Schedule.intersect(Schedule.recurs(12)),
);

/**
 * Records the machine's kind (module docs) after the create response when the
 * route gives a hook, detached otherwise. Never fails.
 */
export function scheduleGuestVmKindRecord(
  providers: VmProviderGatewayShape,
  row: CloudVmRow,
  defer: ((work: Effect.Effect<void>) => void) | undefined,
  retry: Schedule.Schedule<unknown> = GUEST_VM_KIND_RETRY,
): Effect.Effect<void> {
  const providerVmId = row.providerVmId;
  const kind = guestVmKindToRecord(row);
  if (!providerVmId || !kind) return Effect.void;
  const command = guestVmKindCommand(kind);
  const work = Effect.suspend(() =>
    providers.exec(row.provider, providerVmId, command, {
      timeoutMs: 10_000,
      providerMetadata: row.providerMetadata,
      // /etc/cmux is root-owned, and the marker must be too.
      asRoot: true,
    })
  ).pipe(
    // The command exits 0 only after `written` or `kept`; anything else (a
    // silent or timed-out exec included) is tried again.
    Effect.flatMap((result) => result.exitCode === 0
      ? Effect.succeed(result.stdout.trim().split("\n").at(-1) ?? "")
      : Effect.fail(new Error(`vm-kind write exited ${result.exitCode}`))),
    Effect.retry(retry),
    Effect.flatMap((outcome) => Effect.logDebug("Cloud vm-kind marker", { vmId: row.id, kind, outcome })),
    Effect.catchAllCause((cause) => Effect.logWarning("Cloud vm-kind marker not written", { vmId: row.id, kind, cause })),
  );
  if (defer) {
    defer(work);
    return Effect.void;
  }
  return Effect.asVoid(Effect.forkDaemon(work));
}
