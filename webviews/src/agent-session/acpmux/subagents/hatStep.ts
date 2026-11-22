// What the composer hat says a running subagent does now (hatStep.experiment.ts), as data: the word
// for the kind of call it is on, from the bounded list below, never the call itself (Leo,
// 2026-11-22: "we dont show the exact calls, ever, at the top. then we therefore understand what will
// pop up as they come"). The kind comes from acpmux (`actionKind`, its `tool_kind`, or the ACP kind of
// the subagent's own call); the hat only words it.
import type { Translate } from "../i18n";

/// Every word the phase slot can say, in the order the slot stacks them: the slot is as wide as the
/// widest of them in the pane's language, so no change of word moves anything after it.
export const HAT_PHASES = [
  "thinking",
  "reading",
  "searching",
  "editing",
  "running",
  "fetching",
  "delegating",
  "working",
] as const;
export type HatPhase = (typeof HAT_PHASES)[number];

/// The least time a word stays before the next replaces it, so a burst of fifty calls reads as a few
/// calm changes of word, not fifty (design/composer-hat-calm.md).
export const PHASE_DWELL_MS = 1_600;
/// The sampled arm's least time between two exact calls.
export const SAMPLE_DWELL_MS = 2_500;

/// The phase for a subagent's last call: its ACP kind, else a shell call's flag; with no call yet it
/// is thinking, and a call of a kind the list has no word for is working.
export function hatPhase(agent: { action?: string; actionKind?: string; actionShell?: boolean }): HatPhase {
  const kind = agent.actionKind ?? (agent.actionShell ? "execute" : undefined);
  switch (kind) {
    case "read":
      return "reading";
    case "search":
      return "searching";
    case "edit":
    case "delete":
    case "move":
      return "editing";
    case "execute":
      return "running";
    case "fetch":
      return "fetching";
    case "think":
      return "delegating";
    default:
      return agent.action === undefined && kind === undefined ? "thinking" : "working";
  }
}

/// The word a phase reads as.
export function hatPhaseWord(t: Translate, phase: HatPhase): string {
  return phase === "thinking" ? t("thinking") : t(`hat.step.${phase}`);
}
