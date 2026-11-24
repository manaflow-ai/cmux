import { useState } from "react";
import { ChevronRight } from "./icons";
import { copyTextResult } from "./clipboard";
import { useT } from "../i18n";

/// An error's own words, one click away (Lawrence, 2026-11-07: "we need better error messages in the
/// chat ui itself"): every error line in the chat says what happened in plain words and what to do,
/// and the agent's, acpmux's or the updater's raw text waits here, under Details, with Copy error
/// beside it for a bug report. Closed by default; the chat's chevron, never the browser's triangle.
/// The failed turn card, the start-failed card and the agent CLI line all draw it, so the three read
/// and copy the same way.
export function ErrorDetails({ text, className }: { text: string; className?: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  return (
    <details
      className={className ? `cv-turn-error__details ${className}` : "cv-turn-error__details"}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary className="cv-turn-note__summary">
        {t("turn.failure.details")}
        <ChevronRight size={12} aria-hidden="true" className={`cv-rotor${open ? " is-open" : ""}`} />
      </summary>
      <span className="cv-turn-error__raw">
        <span data-error-detail className="block font-mono text-detail whitespace-pre-wrap text-dim select-text">
          {text}
        </span>
        <button
          type="button"
          className="cv-turn-auth-action"
          onClick={() =>
            void copyTextResult(text).then(
              (accepted) => setCopied(accepted),
              () => setCopied(false),
            )
          }
        >
          {copied ? t("turn.copied") : t("turn.failure.copyError")}
        </button>
      </span>
    </details>
  );
}
