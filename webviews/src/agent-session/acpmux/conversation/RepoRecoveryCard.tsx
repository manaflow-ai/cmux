import { useEffect, useRef, useState } from "react";
import { postNative } from "../native";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";

type Choice = { fullName: string; private?: boolean; source?: string };
export type RepoRecovery = {
  code: string;
  org?: string;
  installUrl?: string;
  choices?: Choice[];
  retry?: { action: string; args: Record<string, unknown>; wait_action?: string };
};

function payload(text: string | undefined): Record<string, unknown> | undefined {
  if (!text) return undefined;
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return undefined;
  try {
    const parsed = JSON.parse(text.slice(start, end + 1));
    if (parsed && typeof parsed === "object") return parsed as Record<string, unknown>;
  } catch {
    // Tool output may have a prose prefix; try the next JSON object below.
  }
  return undefined;
}

function githubInstallUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "github.com" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function typedFailure(value: unknown): never | void {
  if (value && typeof value === "object" && typeof (value as { code?: unknown }).code === "string")
    throw new Error((value as { code: string }).code);
}

export function repoRecoveryFor(tool: NonNullable<AcpmuxActivity["tool"]>): RepoRecovery | undefined {
  if (
    tool.title !== "list_repos" &&
    tool.title !== "add_repo" &&
    !tool.title.endsWith(".list_repos") &&
    !tool.title.endsWith(".add_repo")
  )
    return undefined;
  const data = payload(tool.output);
  const code = data?.code;
  if (code !== "repo.needs_github" && code !== "repo.no_access" && code !== "repo.ambiguous") return undefined;
  const retry = data?.retry;
  const rawArgs = retry && typeof retry === "object" ? (retry as { args?: unknown }).args : undefined;
  const args = rawArgs && typeof rawArgs === "object" ? (rawArgs as Record<string, unknown>) : undefined;
  const safeArgs =
    typeof args?.repo === "string"
      ? { repo: args.repo, ...(typeof args.ref === "string" ? { ref: args.ref } : {}) }
      : undefined;
  return {
    code,
    org: typeof data?.org === "string" ? data.org : undefined,
    installUrl: githubInstallUrl(data?.install_url),
    choices: Array.isArray(data?.choices)
      ? data.choices.filter((choice): choice is Choice => Boolean(choice) && typeof choice.fullName === "string")
      : undefined,
    retry:
      (retry as { action?: unknown } | undefined)?.action === "cloud.repo.add" && safeArgs
        ? {
            action: "cloud.repo.add",
            args: safeArgs,
            wait_action:
              (retry as { wait_action?: unknown }).wait_action === "cloud.repo.wait_github"
                ? "cloud.repo.wait_github"
                : undefined,
          }
        : undefined,
  };
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
    void postNative<{ connected?: boolean }>(recovery.retry.wait_action ?? "cloud.repo.wait_github", {
      timeout_ms: 60_000,
    })
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
