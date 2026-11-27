import { type ReactNode, useState } from "react";
import { copyTextResult } from "./conversation/clipboard";
import { useT } from "./i18n";
import { askOwnerRequest, type MachineShareOutcome, offersMachineShare, shareMachineWithMe } from "./machineShare";

/// What the start refusal card needs to share a teammate's machine: its name (for Ask the Owner's
/// request) and the native `machine.share.self` call.
export type MachineShareProps = { machine?: string; call(): Promise<unknown> };

type Phase =
  | { kind: "idle" }
  | { kind: "sharing" }
  | { kind: "forbidden" }
  | { kind: "copied" }
  | { kind: "failed"; outcome: Extract<MachineShareOutcome, { kind: "failed" }> };

/// The card's one share button and its one status line, for a teammate's machine only
/// (machineShare.ts). One button at a time keeps the card compact: Share with Me, and once that is
/// refused (only the creator or an admin shares), Ask the Owner in its place. A share that went
/// through starts the chat again and resends the refused prompt (`onShared`: the refusal handed it
/// back to the composer, and a chat on another machine starts only with a send). Once the owner was
/// asked, Retry looks for their share first (`retry`): shared resends, else a plain retry. The state
/// belongs to one refusal: a new one starts over.
export function useMachineShare(
  share: MachineShareProps | undefined,
  refusal: { code?: string; error?: string } | undefined,
  onRetry: () => void,
  onShared: () => void = onRetry,
): { button?: ReactNode; line?: string; retry?: () => void } {
  const t = useT();
  const key = `${refusal?.code ?? ""}\n${refusal?.error ?? ""}`;
  const [state, setState] = useState<{ key: string; phase: Phase }>({ key, phase: { kind: "idle" } });
  if (!share || !offersMachineShare(refusal?.code)) return {};
  const phase: Phase = state.key === key ? state.phase : { kind: "idle" };
  const set = (next: Phase) => setState({ key, phase: next });
  const run = async () => {
    set({ kind: "sharing" });
    const outcome = await shareMachineWithMe(share.call);
    if (outcome.kind === "shared") {
      set({ kind: "idle" });
      onShared();
    } else if (outcome.kind === "forbidden") set({ kind: "forbidden" });
    else set({ kind: "failed", outcome });
  };
  const ask = async () => {
    const copied = await copyTextResult(askOwnerRequest(t, share.machine));
    set(copied ? { kind: "copied" } : { kind: "forbidden" });
  };
  const asking = phase.kind === "forbidden" || phase.kind === "copied";
  // Once the owner was asked, Retry first checks for their share (the app renews the machine's link
  // when the person is on its grants), then starts again either way.
  const recheck = async () => {
    const outcome = await shareMachineWithMe(share.call);
    if (outcome.kind !== "shared") return onRetry();
    set({ kind: "idle" });
    onShared();
  };
  const button = asking ? (
    <button type="button" data-machine-share="ask" onClick={() => void ask()}>
      {t("switch.action.askOwner")}
    </button>
  ) : (
    <button type="button" data-machine-share="share" disabled={phase.kind === "sharing"} onClick={() => void run()}>
      {t("switch.action.shareWithMe")}
    </button>
  );
  const line =
    phase.kind === "forbidden"
      ? t("switch.share.forbidden")
      : phase.kind === "copied"
        ? t("switch.askOwner.copied")
        : phase.kind === "failed"
          ? t(phase.outcome.key, { reason: phase.outcome.reason ?? t("switch.unknownError") })
          : undefined;
  return { button, ...(line && { line }), ...(asking && { retry: () => void recheck() }) };
}
