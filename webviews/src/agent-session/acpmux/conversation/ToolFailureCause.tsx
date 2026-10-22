// A failed tool call's word and cause (toolFailure.ts): the word on the row in the theme's error
// tone, the cause in the transcript's quiet text where the `tool-error-look` experiment puts it.
// The cause repeats words of the call's result, so Find in Chat skips it and counts the result.
import { useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import type { Translate } from "../i18n";
import { useT } from "../i18n";
import { copyText } from "./clipboard";
import { toolErrorLook } from "./toolError.experiment";
import type { ToolFailure } from "./toolFailure";

/// What happened, in a word: blocked, denied, timed out, Exit 1, failed.
export function failureWord(t: Translate, failure: ToolFailure): string {
  switch (failure.kind) {
    case "hook":
      return t("tools.blocked");
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

/// The hook that refused the call, before its reason ("PreToolUse"), in the quiet mono of a name.
function HookName({ failure }: { failure: ToolFailure }) {
  return failure.hook ? <code className="cv-tool-error__hook">{failure.hook}</code> : null;
}

/// The cause on the row itself (the `inline` arm): after the call's words, cut with them.
export function InlineFailureCause({ failure }: { failure: ToolFailure | undefined }) {
  if (!failure?.cause || experimentArm(toolErrorLook) !== "inline") return null;
  return (
    <span className="cv-tool-error__inline" data-find-skip>
      {" · "}
      <HookName failure={failure} />
      {failure.cause}
    </span>
  );
}

/// The cause under the row: one dim line (`line`), or a small card with Copy error (`card`).
export function ToolFailureCause({ failure, raw }: { failure: ToolFailure | undefined; raw?: string }) {
  const arm = experimentArm(toolErrorLook);
  if (!failure?.cause || arm === "inline") return null;
  if (arm === "card") return <FailureCard failure={failure} raw={raw} />;
  return (
    <div className="cv-tool-error" data-failure-kind={failure.kind} data-find-skip>
      <HookName failure={failure} />
      {failure.cause}
    </div>
  );
}

function FailureCard({ failure, raw }: { failure: ToolFailure; raw?: string }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  return (
    <div className="cv-tool-error-card" data-failure-kind={failure.kind} data-find-skip>
      <span className="cv-tool-error-card__cause">
        <HookName failure={failure} />
        {failure.cause}
      </span>
      {raw && (
        <button
          type="button"
          className="cv-tool-error-card__copy"
          onClick={() =>
            void copyText(raw).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          {copied ? t("turn.copied") : t("turn.failure.copyError")}
        </button>
      )}
    </div>
  );
}
