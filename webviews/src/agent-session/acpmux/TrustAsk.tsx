import React, { useRef, useState } from "react";
import { projectName } from "./EmptyState";
import { type Translate, useT } from "./i18n";
import { isAgentHome } from "./sessionList";
import type { FolderTrustAsk } from "./useFolderTrustAsk";

/// What the trust question is about, in words: the repository (`repo`, when the folder is in one
/// below home), else the folder. Its name, never its path cut to "/User…".
export function trustSubject(ask: Pick<FolderTrustAsk, "cwd" | "repo" | "via">) {
  const name = (path: string) => projectName(path) ?? path;
  return {
    folder: name(ask.cwd),
    repo: ask.repo ? name(ask.repo.root) : undefined,
    /// The answer came from the repository as a whole (the folder is in it, or one of its worktrees).
    viaRepo: Boolean(ask.repo && ask.via === ask.repo.root),
    /// The answer came from a parent folder that is not the repository.
    viaFolder: ask.via && ask.via !== ask.repo?.root ? name(ask.via) : undefined,
    /// The folder is the repository's main working tree: trusting it and the repository are one.
    atRoot: Boolean(ask.repo && ask.repo.root === ask.cwd),
  };
}

/// What a trusted folder's answer says: through its repository, its worktree's root, the
/// repository itself (only when a person's answer for it holds, not a rule's: `recorded`), or
/// the folder.
export function trustedLabel(t: Translate, scope: Pick<FolderTrustAsk, "cwd" | "repo" | "via"> & { recorded?: false }) {
  const { folder, repo, viaRepo, viaFolder, atRoot } = trustSubject(scope);
  if (viaRepo && repo) return t("trust.trustedViaRepo", { repo });
  if (viaFolder) return t("trust.trustedVia", { folder: viaFolder });
  if (atRoot && repo && scope.recorded !== false) return t("trust.trustedRepo", { repo });
  return t("trust.trusted", { folder });
}

/// The folder trust question among the chat's permission asks, above the composer. It says what
/// is trusted (the repository and every worktree of it, or the folder), what trusting allows, and
/// offers Trust repo (the common case, first), Only this folder, and Not now; then the answer with
/// Undo. An untrusted answer keeps a Trust action beside Undo where the pane can answer, so Not now
/// never hides the recovery path. Nothing waits on it (Leo, 2026-10-21: say what is trusted, what it
/// allows, scoped choices).
export function TrustAsk({
  ask,
  agent,
  onTrust,
  onTrustRepo,
  onDistrust,
  onUndo,
  onContinueWithoutFolder,
  answers = true,
}: {
  ask: FolderTrustAsk;
  agent: string;
  /// This pane can record an answer (not a remote chat whose host keeps it). Without it the card
  /// only says where the folder stands: Trust, Not now and Undo would each send an answer the host
  /// refuses, and that refusal's failed state would offer Trust again.
  answers?: boolean;
  /// Trust only this folder.
  onTrust(): void;
  /// Trust the repository holding the folder (every worktree of it).
  onTrustRepo?(): void;
  onDistrust(): void;
  onUndo(): void;
  /// Continue in the private no-project chat after explicitly declining this folder.
  onContinueWithoutFolder?(): void | Promise<void>;
}) {
  const t = useT();
  const [continuing, setContinuing] = useState(false);
  const continuingRef = useRef(false);
  const [continueError, setContinueError] = useState(false);
  // A workspace's new chat starts in its private folder under Application Support: named in words.
  const owned = isAgentHome(ask.cwd);
  const subject = trustSubject(ask);
  const { folder, repo } = subject;
  const recovery = ask.state === "decided" && ask.level === "untrusted" && answers && !!onContinueWithoutFolder;
  const asking = ask.state === "ask" || ask.state === "failed";
  // The repository is offered whole only when the pane can record it (`onTrustRepo`).
  const offersRepo = Boolean(repo && onTrustRepo && !owned);
  // After Not now, Trust repo only where that answer lives (`trust.rs`: the folder's own answer,
  // then its worktree's, then its repository's). Else Trust records the folder, which answers first.
  const retrustsRepo = offersRepo && (subject.viaRepo || subject.atRoot);
  return (
    // An open question reads as one (full text, the accent's edge, the primary answer first), not
    // as the quiet receipt it becomes once answered: a dim line was easy to miss while the agent
    // waited on it (Leo, 2026-10-21).
    <div
      className="acpmux-trust-ask"
      data-asking={asking || undefined}
      data-recovery={recovery || undefined}
      aria-live="polite"
    >
      {ask.state === "decided" && ask.level === "untrusted" ? (
        <>
          <span className={recovery ? "acpmux-trust-ask-body" : "acpmux-trust-ask-text"}>
            <span className="acpmux-trust-ask-text">
              {owned
                ? t("trust.untrustedPrivate")
                : (subject.viaRepo || subject.atRoot) && repo
                  ? t("trust.notTrustedRepo", { agent, repo })
                  : t("trust.notTrusted", { agent, folder: subject.viaFolder ?? folder })}
            </span>
            {answers && onContinueWithoutFolder && (
              <span className="acpmux-trust-ask-detail">{t("trust.continueWithoutFolder")}</span>
            )}
            {continueError && <span role="alert">{t("trust.failed")}</span>}
          </span>
          <span className="acpmux-trust-ask-actions">
            {!answers ? null : retrustsRepo ? (
              <button
                type="button"
                className="acpmux-trust-ask-action acpmux-trust-ask-primary"
                disabled={continuing}
                onClick={onTrustRepo}
              >
                {t("trust.trustRepo")}
              </button>
            ) : (
              <button
                type="button"
                className="acpmux-trust-ask-action acpmux-trust-ask-primary"
                disabled={continuing}
                onClick={onTrust}
              >
                {owned ? t("trust.trust") : t("trust.trustFolder")}
              </button>
            )}
            {answers && (
              <>
                {onContinueWithoutFolder && (
                  <button
                    type="button"
                    className="acpmux-trust-ask-action"
                    disabled={continuing}
                    onClick={() => {
                      if (continuingRef.current) return;
                      continuingRef.current = true;
                      setContinuing(true);
                      setContinueError(false);
                      void Promise.resolve()
                        .then(onContinueWithoutFolder)
                        .catch(() => setContinueError(true))
                        .finally(() => {
                          continuingRef.current = false;
                          setContinuing(false);
                        });
                    }}
                  >
                    {t("trust.continueWithoutFolderLabel")}
                  </button>
                )}
                <button type="button" className="acpmux-trust-ask-action" disabled={continuing} onClick={onUndo}>
                  {t("trust.undo")}
                </button>
              </>
            )}
          </span>
        </>
      ) : ask.state === "decided" ? (
        <>
          <span className="acpmux-trust-ask-text">
            {ask.level === "trusted"
              ? owned
                ? t("trust.trustedPrivate")
                : trustedLabel(t, ask)
              : owned
                ? t("trust.untrustedPrivate")
                : (subject.viaRepo || subject.atRoot) && repo
                  ? t("trust.notTrustedRepo", { agent, repo })
                  : t("trust.notTrusted", { agent, folder: subject.viaFolder ?? folder })}
          </span>
          {answers && (
            <button type="button" className="acpmux-trust-ask-action" onClick={onUndo}>
              {t("trust.undo")}
            </button>
          )}
        </>
      ) : ask.state === "remote" ? (
        <span className="acpmux-trust-ask-text">{t("trust.remote")}</span>
      ) : owned ? (
        <>
          <span className="acpmux-trust-ask-text">
            {ask.state === "failed" ? t("trust.failed") : t("trust.askPrivate", { agent })}
          </span>
          {answers && (
            <>
              <button type="button" className="acpmux-trust-ask-action acpmux-trust-ask-primary" onClick={onTrust}>
                {t("trust.trust")}
              </button>
              <button type="button" className="acpmux-trust-ask-action" onClick={onDistrust}>
                {t("trust.notNow")}
              </button>
            </>
          )}
        </>
      ) : (
        <>
          <span className="acpmux-trust-ask-body">
            <span className="acpmux-trust-ask-text">
              {ask.state === "failed"
                ? t("trust.failed")
                : offersRepo && repo
                  ? t("trust.askRepo", { repo })
                  : t("trust.askFolder", { folder })}
            </span>
            <span className="acpmux-trust-ask-detail">
              {offersRepo
                ? subject.atRoot
                  ? t("trust.allowsRepo", { agent })
                  : t("trust.allowsRepoFrom", { agent, folder })
                : t("trust.allowsFolder", { agent })}
            </span>
          </span>
          {answers && (
            <span className="acpmux-trust-ask-actions">
              {offersRepo ? (
                <>
                  <button
                    type="button"
                    className="acpmux-trust-ask-action acpmux-trust-ask-primary"
                    onClick={onTrustRepo}
                  >
                    {t("trust.trustRepo")}
                  </button>
                  {!subject.atRoot && (
                    <button type="button" className="acpmux-trust-ask-action" onClick={onTrust}>
                      {t("trust.onlyThisFolder")}
                    </button>
                  )}
                </>
              ) : (
                <button type="button" className="acpmux-trust-ask-action acpmux-trust-ask-primary" onClick={onTrust}>
                  {t("trust.trustFolder")}
                </button>
              )}
              <button type="button" className="acpmux-trust-ask-action" onClick={onDistrust}>
                {t("trust.notNow")}
              </button>
            </span>
          )}
        </>
      )}
    </div>
  );
}
