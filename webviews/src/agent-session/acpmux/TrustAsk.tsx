import React from "react";
import { projectName } from "./EmptyState";
import { useT } from "./i18n";
import { isAgentHome } from "./sessionList";
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
  // A workspace's new chat starts in its private folder under Application Support: named in words,
  // never its path cut to "/User…". The path stays in the tooltip.
  const owned = isAgentHome(ask.cwd);
  const folder = projectName(ask.cwd) ?? ask.cwd;
  return (
    <div className="acpmux-trust-ask" aria-live="polite">
      {ask.state === "decided" ? (
        <>
          <span className="acpmux-trust-ask-text">
            {ask.level === "trusted"
              ? owned
                ? t("trust.trustedPrivate")
                : t("trust.trusted", { folder })
              : owned
                ? t("trust.untrustedPrivate")
                : t("trust.untrusted", { folder })}
          </span>
          <button type="button" className="acpmux-trust-ask-action" onClick={onUndo}>
            {t("trust.undo")}
          </button>
        </>
      ) : ask.state === "remote" ? (
        <span className="acpmux-trust-ask-text">{t("trust.remote")}</span>
      ) : (
        <>
          <span className="acpmux-trust-ask-text">
            {ask.state === "failed"
              ? t("trust.failed")
              : owned
                ? t("trust.askPrivate", { agent })
                : t("trust.ask", { agent, folder })}
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
