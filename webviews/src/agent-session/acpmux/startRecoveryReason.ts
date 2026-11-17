// Which start-recovery state a failed start is in (StartRecovery.tsx): one shared view for the
// starts that failed for a reason the person can fix in one step. Leo: "you should still be able
// to, like, select the thing and then start the thing ... some sort of pop over ... some pretty
// pictures even ... really concise, actionable things, like, hey, this is what you need to do for
// this reason" (cmuxterm-hq plans/next-ux/ux-start-anyway.md, first slice).
//
// Only evidence makes a state: acpmux's typed not-installed refusal or the start's own words, read
// by the classifiers the start-failed card already uses (startFailure.ts, failureCopy.ts). An old
// CLI, an unknown auth state, quota and every other failure stay on the start-failed card.
import { failureKind } from "./failureCopy";
import { startNotInstalled } from "./startFailure";
import { startRefusalAction } from "./startRefusal";

export type StartRecoveryReason = "missing-harness" | "signed-out" | "offline";

export type FailedStart = { harness: string; name: string; error?: string; code?: string };

/// The recovery state of a failed start, or undefined when the start-failed card answers it.
export function startRecoveryReason(start: FailedStart | undefined): StartRecoveryReason | undefined {
  if (!start) return undefined;
  if (startNotInstalled(start)) return "missing-harness";
  const raw = start.error?.trim();
  // A refusal coded with its own way out (a folder, a Cloud machine) keeps its own card.
  if (!raw || startRefusalAction(start.code)) return undefined;
  switch (failureKind(raw, { name: start.name, harness: start.harness }, start.code)) {
    // Only a provider login asks to sign in; a rejected key or proxy credential is not a sign-in.
    case "subscription-login":
    case "cloud-auth-expired":
      return "signed-out";
    case "unreachable":
    case "tailscale":
      return "offline";
    default:
      return undefined;
  }
}
