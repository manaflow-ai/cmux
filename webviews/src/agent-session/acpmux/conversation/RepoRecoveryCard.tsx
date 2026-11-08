import { useEffect, useRef, useState } from "react";
import { postNative } from "../native";

import { useT } from "../i18n";
import { type RepoRecovery } from "./repoRecoveryCardModel";
function typedFailure(value: unknown): never | void {
  if (value && typeof value === "object" && typeof (value as { code?: unknown }).code === "string")
    throw new Error((value as { code: string }).code);
}

export function RepoRecoveryCard({ recovery }: { recovery: RepoRecovery }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "waiting" | "retrying" | "done" | "failed">("idle");
  const [choice, setChoice] = useState<string>();
  const mounted = useRef(true);
  useEffect(
    () => () => {
      mounted.current = false;
    },
    [],
  );
  const connect = () => {
    if (!recovery.installUrl) return;
    window.open(recovery.installUrl, "_blank", "noopener,noreferrer");
    if (!recovery.retry) return;
    setState("waiting");
    void postNative<{ connected?: boolean }>(recovery.retry.wait_action ?? "cloud.repo.wait_github")
      .then((reply) => {
        if (!mounted.current) return;
        if (!reply?.connected) {
          setState("idle");
          return;
        }
        setState("retrying");
        return postNative(recovery.retry!.action, recovery.retry!.args).then((value) => typedFailure(value));
      })
      .then(
        () => mounted.current && setState("done"),
        () => mounted.current && setState("failed"),
      );
  };
  const select = (repo: string) => {
    setChoice(repo);
    if (!recovery.retry) return;
    setState("retrying");
    void postNative(recovery.retry.action, { ...recovery.retry.args, repo })
      .then((value) => typedFailure(value))
      .then(
        () => setState("done"),
        () => setState("failed"),
      );
  };

  if (state === "done")
    return <div className="cv-repo-recovery cv-repo-recovery--done">{t("cloudRepository.attached")}</div>;
  if (state === "waiting" || state === "retrying")
    return (
      <div className="cv-repo-recovery cv-repo-recovery--quiet">
        {state === "waiting" ? t("cloudRepository.connecting") : t("cloudRepository.pending")}
      </div>
    );
  if (state === "failed")
    return (
      <div className="cv-repo-recovery cv-repo-recovery--error" role="alert">
        {t("cloudRepository.recoverFailed")}
      </div>
    );
  if (recovery.code === "repo.needs_github")
    return (
      <div className="cv-repo-recovery cv-repo-recovery--quiet">
        <span>{t("cloudRepository.connecting")}</span>
        {recovery.installUrl && (
          <button type="button" onClick={connect}>
            {t("cloudRepository.connect")}
          </button>
        )}
      </div>
    );
  if (recovery.code === "repo.no_access")
    return (
      <div className="cv-repo-recovery">
        <span>
          {t("cloudRepository.noAccess", {
            target: recovery.org
              ? t("cloudRepository.repositories", { org: recovery.org })
              : t("cloudRepository.thisRepository"),
          })}
        </span>
        {recovery.installUrl && (
          <button type="button" onClick={connect}>
            {t("cloudRepository.installOn", { target: recovery.org ?? t("cloudRepository.github") })}
          </button>
        )}
        <button
          type="button"
          onClick={() =>
            window.open(
              `https://github.com/orgs/${encodeURIComponent(recovery.org ?? "")}`,
              "_blank",
              "noopener,noreferrer",
            )
          }
        >
          {t("cloudRepository.requestAccess")}
        </button>
      </div>
    );
  if (recovery.code === "repo.ambiguous" && recovery.choices?.length)
    return (
      <fieldset className="cv-repo-recovery" aria-label={t("cloudRepository.choose")}>
        <span>{t("cloudRepository.which")}</span>
        {recovery.choices.map((item) => (
          <button
            key={item.fullName}
            type="button"
            aria-pressed={choice === item.fullName}
            onClick={() => select(item.fullName)}
          >
            {item.fullName}
          </button>
        ))}
      </fieldset>
    );
  return null;
}
