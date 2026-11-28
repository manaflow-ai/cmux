// The Branch scope's Create PR (cx-tcwj, Codex desktop's): the App opens the pushed branch's pull
// request, and the view links it where the button was. Progress and refusals show inline, never
// in a dialog.
import React, { useState } from "react";
import { useT } from "../i18n";

type Status =
  | { kind: "opening" }
  | { kind: "opened"; url: string; number?: number }
  | { kind: "failed"; message: string };

/// `{url, number}` from the host, when the url is an https link.
export function openedPullRequest(value: unknown): { url: string; number?: number } | undefined {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  if (typeof raw.url !== "string" || !raw.url.startsWith("https://")) return undefined;
  return { url: raw.url, number: typeof raw.number === "number" ? raw.number : undefined };
}

export function PullRequestButton({ open }: { open: () => Promise<unknown> }) {
  const t = useT();
  const [status, setStatus] = useState<Status>();
  const run = () => {
    if (status?.kind === "opening") return;
    setStatus({ kind: "opening" });
    open().then(
      (value) => {
        const opened = openedPullRequest(value);
        setStatus(opened ? { kind: "opened", ...opened } : { kind: "failed", message: t("changes.pullRequestFailed") });
      },
      (error: unknown) =>
        setStatus({
          kind: "failed",
          message: error instanceof Error && error.message ? error.message : t("changes.pullRequestFailed"),
        }),
    );
  };
  if (status?.kind === "opened")
    return (
      <output className="acpmux-pull-request">
        {/* A click opens it outside the pane (AgentPaneNavigation). */}
        <a href={status.url} target="_blank" rel="noreferrer">
          {status.number === undefined
            ? t("changes.pullRequest")
            : t("changes.pullRequestNumber", { n: status.number })}
        </a>
      </output>
    );
  return (
    <>
      <button type="button" className="acpmux-pull-request-create" disabled={status?.kind === "opening"} onClick={run}>
        {t("changes.createPullRequest")}
      </button>
      {status?.kind === "opening" && <output className="acpmux-pull-request">{t("changes.openingPullRequest")}</output>}
      {status?.kind === "failed" && (
        <span className="acpmux-pull-request" role="alert">
          {status.message}
        </span>
      )}
    </>
  );
}
