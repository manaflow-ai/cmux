import React from "react";
import { projectName } from "./EmptyState";
import { useT } from "./i18n";
import type { FolderTrustAsk } from "./useFolderTrustAsk";

/// One quiet line among the chat's permission asks, above the composer: what the agent may do in
/// this folder, with Trust and Don't trust, then the answer with Undo. Nothing waits on it.
export function TrustAsk({
  ask,
  agent,
  onTrust,
  onDistrust,
  onUndo,
}: {
  ask: FolderTrustAsk;
  agent: string;
  onTrust(): void;
  onDistrust(): void;
  onUndo(): void;
}) {
  const t = useT();
  const folder = projectName(ask.cwd) ?? ask.cwd;
  return (
    <div className="acpmux-trust-ask" aria-live="polite" title={ask.cwd}>
      {ask.state === "decided" ? (
        <>
          <span className="acpmux-trust-ask-text">
            {t(ask.level === "trusted" ? "trust.trusted" : "trust.untrusted", { folder })}
          </span>
          <button type="button" className="acpmux-trust-ask-action" onClick={onUndo}>
            {t("trust.undo")}
          </button>
        </>
      ) : (
        <>
          <span className="acpmux-trust-ask-text">
            {ask.state === "failed" ? t("trust.failed") : t("trust.ask", { agent, folder })}
          </span>
          <button type="button" className="acpmux-trust-ask-action" onClick={onTrust}>
            {t("trust.trust")}
          </button>
          <button type="button" className="acpmux-trust-ask-action" onClick={onDistrust}>
            {t("trust.distrust")}
          </button>
        </>
      )}
    </div>
  );
}
