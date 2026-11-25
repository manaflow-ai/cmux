// What the running turn's live line waits on, said in its words, never a bare "Waiting" (Leo,
// 2026-11-22: "everything that goes in there write more detailed things than just waiting"). Pure
// derivation from the turn's rows that turns.ts `codexLiveTurn` already shapes for the line: the
// webview builds the live line from those rows, and acpmux sends no per-line wait of its own, so the
// words are chosen here, next to the line's other labels (Thinking.tsx), not in the daemon.
import type { Translate } from "../i18n";

/// Past SILENT_MS with nothing heard (Thinking.tsx `silent`) the model is still working on the
/// turn's next request; what it last heard says which one:
/// - `prompt`: nothing from the model since the prompt (or a notice) set the turn going.
/// - `step`: the call `step` names just returned, and the model reads its result.
/// - `message`: another agent's message (`from`) just came in.
/// - `queued`: the person's message waits in the turn for the agent to read it.
/// - `next`: after a thought or a reply, the model's next step.
export type LiveWait =
  | { kind: "prompt" }
  | { kind: "step"; step: string }
  | { kind: "message"; from: string }
  | { kind: "queued" }
  | { kind: "next" };

const waitKey = (wait: LiveWait | undefined): string =>
  wait === undefined
    ? ""
    : wait.kind === "step"
      ? `step:${wait.step}`
      : wait.kind === "message"
        ? `message:${wait.from}`
        : wait.kind;

/// The row memo's comparison (ThinkingRow.tsx): a fresh object with the same words draws nothing.
export const sameLiveWait = (a: LiveWait | undefined, b: LiveWait | undefined): boolean => waitKey(a) === waitKey(b);

/// The silent line's words: "Waiting on the model after Read App.tsx", never "Waiting".
export function waitingLabel(t: Translate, wait: LiveWait | undefined): string {
  switch (wait?.kind) {
    case "prompt":
      return t("turn.live.waitingFirstReply");
    case "step":
      return t("turn.live.waitingAfterStep", { step: wait.step });
    case "message":
      return t("turn.live.waitingAfterMessage", { from: wait.from });
    case "queued":
      return t("turn.live.waitingQueued");
    default:
      return t("turn.live.waitingNextStep");
  }
}

/// The subagent wait names whom it waits on, by the names the tray shows: "Waiting on subagent
/// Explore auth", "Waiting on subagents lint and tests", "Waiting on subagent lint and 3 more". With
/// no names known (subagents only the tray counts), the count alone: "Waiting on 2 subagents".
export function subagentsLabel(t: Translate, n: number, names: readonly string[] = []): string {
  const [first, second] = names;
  if (first === undefined) return t("turn.live.waitingOnSubagents", { n });
  if (n <= 1) return t("turn.live.waitingOnSubagent", { name: first });
  if (n === 2 && second !== undefined) return t("turn.live.waitingOnSubagentPair", { first, second });
  return t("turn.live.waitingOnSubagentMore", { name: first, n: n - 1 });
}

export const sameNames = (a: readonly string[] | undefined, b: readonly string[] | undefined): boolean =>
  a === b || (a !== undefined && b !== undefined && a.length === b.length && a.every((name, i) => name === b[i]));
