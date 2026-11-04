// A failed tool call's word and cause (toolFailure.ts): the word on the row in the theme's error
// tone, the cause in the transcript's quiet text where the `tool-error-look` experiment puts it.
// The cause repeats words of the call's result, so Find in Chat skips it and counts the result.
import { createContext, useContext } from "react";
import { experimentArm } from "../../../experiments/experiment";
import type { Translate } from "../i18n";
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";
import { toolErrorLook } from "./toolError.experiment";
import type { ToolFailure } from "./toolFailure";

/// True for a call drawn as one step of an opened "Ran N commands", "Read N files" or "Searched N"
/// group (ToolGroupRow.tsx `Step`); a lone call, also one in an opened run, keeps its Exit word and cause.
/// A failed step reads as one plain line, what failed and the word "failed", with no shell
/// wording ("Exit 1") and no cause line under it; the error output waits behind the step's own
/// disclosure, in its Shell block, which says the exit code. The group's head already counts the
/// failure ("1 failed"). Leo said yes (2026-11-02) to a "Scheduled check" whose "Ran 4 commands
/// 1 failed" opened to a raw "(eval):1: ==== not found" line under a step and "Exit 1" at its edge.
export const InStep = createContext(false);

/// Whether this call is a step of an opened group (`InStep`).
export const useInStep = () => useContext(InStep);

/// What happened, in a word: blocked, denied, timed out, Exit 1, failed. A step (`InStep`) says
/// "failed" for a nonzero exit; its Shell block names the code.
export function failureWord(t: Translate, failure: ToolFailure, step = false): string {
  switch (failure.kind) {
    case "hook":
      return t("tools.blockedByHook");
    case "denied":
      return t("tools.denied");
    case "timeout":
      return t("tools.timedOut");
    case "exit":
      return step ? t("tools.failed") : t("tools.exit", { code: failure.exitCode ?? 1 });
    default:
      return t("tools.failed");
  }
}

/// A cause drawn on or under the row: never a hook's, whose row says "blocked by hook" and whose
/// words are the opened call's output, as Claude Code desktop draws a blocked call (Leo,
/// 2026-10-31: "WHY IS THERE PRETOOLUSE").
const drawnCause = (failure: ToolFailure | undefined) => (failure?.kind === "hook" ? undefined : failure?.cause);

/// The cause on the row itself (the `inline` arm): after the call's words, cut with them.
export function InlineFailureCause({ failure }: { failure: ToolFailure | undefined }) {
  const step = useInStep();
  if (step || !failure || !drawnCause(failure)) return null;
  if (experimentArm(toolErrorLook) !== "inline") return null;
  return (
    <span className="cv-tool-error__inline" data-find-skip>
      {" · "}
      {failure.cause}
    </span>
  );
}

/// The cause under the row: one dim line (`line`), or a small card with Copy error (`card`).
export function ToolFailureCause({ failure }: { failure: ToolFailure | undefined }) {
  // A step's error output waits behind its disclosure (`InStep`).
  const step = useInStep();
  // A call that did not fail reads no experiment (a localStorage read) on each render.
  if (step || !failure || !drawnCause(failure)) return null;
  const arm = experimentArm(toolErrorLook);
  if (arm === "inline") return null;
  if (arm === "card") return <FailureCard failure={failure} />;
  return (
    <div className="cv-tool-error" data-failure-kind={failure.kind} data-find-skip>
      {failure.cause}
    </div>
  );
}

function FailureCard({ failure }: { failure: ToolFailure }) {
  const t = useT();
  return (
    <div className="cv-tool-error-card" data-failure-kind={failure.kind} data-find-skip>
      <span className="cv-tool-error-card__cause">{failure.cause}</span>
      {failure.detail && (
        <CopyButton
          text={failure.detail}
          label={t("turn.failure.copyError")}
          className="cv-tool-error-card__copy"
          size={14}
        />
      )}
    </div>
  );
}
