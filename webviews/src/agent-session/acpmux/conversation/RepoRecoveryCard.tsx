import { useState } from "react";
import { postNative } from "../native";
import type { AcpmuxActivity } from "../model";

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

export function repoRecoveryFor(tool: NonNullable<AcpmuxActivity["tool"]>): RepoRecovery | undefined {
  if (tool.title !== "list_repos" && tool.title !== "add_repo" && !tool.title.endsWith(".list_repos") && !tool.title.endsWith(".add_repo"))
    return undefined;
  const data = payload(tool.output);
  const code = data?.code;
  if (code !== "repo.needs_github" && code !== "repo.no_access" && code !== "repo.ambiguous") return undefined;
  const retry = data?.retry;
  return {
    code,
    org: typeof data?.org === "string" ? data.org : undefined,
    installUrl: typeof data?.install_url === "string" ? data.install_url : undefined,
    choices: Array.isArray(data?.choices)
      ? data.choices.filter((choice): choice is Choice => Boolean(choice) && typeof choice.fullName === "string")
      : undefined,
    retry:
      retry && typeof retry === "object" && typeof (retry as { action?: unknown }).action === "string" &&
      (retry as { args?: unknown }).args && typeof (retry as { args: unknown }).args === "object"
        ? {
            action: (retry as { action: string }).action,
            args: (retry as { args: Record<string, unknown> }).args,
            wait_action: typeof (retry as { wait_action?: unknown }).wait_action === "string" ? (retry as { wait_action: string }).wait_action : undefined,
          }
        : undefined,
  };
}

export function RepoRecoveryCard({ recovery }: { recovery: RepoRecovery }) {
  const [state, setState] = useState<"idle" | "waiting" | "retrying" | "done" | "failed">("idle");
  const [choice, setChoice] = useState<string>();
  const session = recovery.retry?.args.session;
  const connect = () => {
    if (!recovery.installUrl) return;
    window.open(recovery.installUrl, "_blank", "noopener,noreferrer");
    if (typeof session !== "string" || !recovery.retry) return;
    setState("waiting");
    void postNative<{ connected?: boolean }>("cloud.repo.wait_github", { session, timeout_ms: 120_000 })
      .then((reply) => {
        if (!reply?.connected) throw new Error("not connected");
        setState("retrying");
        return postNative(recovery.retry!.action, recovery.retry!.args);
      })
      .then(() => setState("done"), () => setState("failed"));
  };
  const select = (repo: string) => {
    setChoice(repo);
    if (!recovery.retry) return;
    setState("retrying");
    void postNative(recovery.retry.action, { ...recovery.retry.args, repo })
      .then(() => setState("done"), () => setState("failed"));
  };

  if (state === "done") return <div className="cv-repo-recovery cv-repo-recovery--done">Repository attached</div>;
  if (state === "waiting" || state === "retrying")
    return <div className="cv-repo-recovery cv-repo-recovery--quiet">{state === "waiting" ? "Connecting GitHub…" : "Attaching repository…"}</div>;
  if (state === "failed")
    return <div className="cv-repo-recovery cv-repo-recovery--error" role="alert">Couldn’t recover this repository action</div>;
  if (recovery.code === "repo.needs_github")
    return (
      <div className="cv-repo-recovery cv-repo-recovery--quiet">
        <span>Connecting GitHub…</span>
        {recovery.installUrl && <button type="button" onClick={connect}>Connect GitHub</button>}
      </div>
    );
  if (recovery.code === "repo.no_access")
    return (
      <div className="cv-repo-recovery">
        <span>No access to {recovery.org ? `${recovery.org} repositories` : "this repository"}</span>
        {recovery.installUrl && <button type="button" onClick={connect}>Install on {recovery.org ?? "GitHub"}</button>}
        <button type="button" onClick={() => window.open("https://github.com/settings/connections/applications", "_blank", "noopener,noreferrer")}>Request access</button>
      </div>
    );
  if (recovery.code === "repo.ambiguous" && recovery.choices?.length)
    return (
      <div className="cv-repo-recovery" role="group" aria-label="Choose repository">
        <span>Which repository?</span>
        {recovery.choices.map((item) => (
          <button key={item.fullName} type="button" aria-pressed={choice === item.fullName} onClick={() => select(item.fullName)}>
            {item.fullName}
          </button>
        ))}
      </div>
    );
  return null;
}
