// A failed tool call's word and cause (toolFailure.ts): the word on the row in the theme's error
// tone, the cause in the transcript's quiet text where the `tool-error-look` experiment puts it.
// The cause repeats words of the call's result, so Find in Chat skips it and counts the result.
import { experimentArm } from "../../../experiments/experiment";
import type { Translate } from "../i18n";
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";
import { toolErrorLook } from "./toolError.experiment";
import type { ToolFailure } from "./toolFailure";

/// What happened, in a word: blocked, denied, timed out, Exit 1, failed.
export function failureWord(t: Translate, failure: ToolFailure): string {
  switch (failure.kind) {
    case "hook":
      return t("tools.blockedByHook");
    case "denied":
      return t("tools.denied");
    case "timeout":
      return t("tools.timedOut");
    case "exit":
      return t("tools.exit", { code: failure.exitCode ?? 1 });
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
  if (!failure || !drawnCause(failure)) return null;
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
  // A call that did not fail reads no experiment (a localStorage read) on each render.
  if (!failure || !drawnCause(failure)) return null;
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
          size={13}
        />
      )}
    </div>
  );
}
