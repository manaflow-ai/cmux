// A reply's checkable claim ("tests pass", "the build succeeds") marked with what its turn's own
// runs say (acpmux hub/claim_check.rs): green when the newest matching run exited 0, red when it
// failed or no run backs it. A click shows that run's row. The mark only colors the phrase's
// underline, so the reply's lines never move when a turn's checks arrive (design/claim-checks.md).
import { createContext, useContext, type ReactNode } from "react";
import { useT } from "../i18n";
import type { ClaimCheck } from "../model";
import { TurnActionsContext } from "./turnActions";
import "./ClaimMark.css";

/// How a mark draws. `underline` ships; the others are the gallery's alternatives.
export type ClaimLook = "underline" | "glyph" | "chip";
export const ClaimLookContext = createContext<ClaimLook>("underline");

export function ClaimMark({ claim, children }: { claim: ClaimCheck; children: ReactNode }) {
  const t = useT();
  const look = useContext(ClaimLookContext);
  const { showCall } = useContext(TurnActionsContext);
  const command = claim.command ?? "";
  const label =
    claim.verdict === "backed"
      ? t("claim.backed", { command })
      : claim.verdict === "failed"
        ? t("claim.failed", { command })
        : t("claim.none");
  const glyph = claim.verdict === "backed" ? "✓" : claim.verdict === "failed" ? "✕" : "?";
  const toolCallId = claim.toolCallId;
  const className = `cv-claim cv-claim--${claim.verdict} cv-claim--${look}`;
  const body = (
    <>
      {children}
      {look === "glyph" && (
        <span className="cv-claim__glyph" aria-hidden="true">
          {glyph}
        </span>
      )}
      {look === "chip" && (
        <span className="cv-claim__chip" aria-hidden="true">
          {glyph} {claim.verdict === "none" ? t("claim.noRun") : command}
        </span>
      )}
    </>
  );
  if (!toolCallId || !showCall)
    return (
      <span className={className} title={label} data-claim-verdict={claim.verdict}>
        {body}
      </span>
    );
  return (
    // A link, not a <button>: a button is an atomic inline box, so a phrase that wrapped as text
    // would jump onto one line when its turn's checks arrive. Going to the run is navigation.
    <a
      href={`#tool-${toolCallId}`}
      className={className}
      title={label}
      aria-label={label}
      data-claim-verdict={claim.verdict}
      onClick={(event) => {
        event.preventDefault();
        showCall(toolCallId);
      }}
    >
      {body}
    </a>
  );
}
