import { useCallback, useEffect, useRef, useState } from "react";
import { translate, useT } from "../agent-session/acpmux/i18n";
import type { ChangesSource } from "../agent-session/acpmux/changes/model";

export type PullRequestAction = {
  available: boolean;
  busy: boolean;
  error?: string;
  run: () => void;
};

/** Runs the host-bound push/Create PR operation once, and ignores replies from an old page source. */
export function usePullRequestAction(source: ChangesSource | undefined): PullRequestAction {
  const [state, setState] = useState<{ busy: boolean; error?: string }>({ busy: false });
  const generation = useRef(0);
  const inFlight = useRef(false);

  useEffect(() => {
    const current = ++generation.current;
    inFlight.current = false;
    setState({ busy: false });
    return () => {
      if (generation.current === current) generation.current += 1;
      inFlight.current = false;
    };
  }, [source]);

  const run = useCallback(() => {
    const pullRequest = source?.pullRequest;
    if (!pullRequest || inFlight.current) return;
    inFlight.current = true;
    const request = generation.current;
    setState({ busy: true });
    void pullRequest()
      .then(
        () => {
          if (generation.current === request) setState({ busy: false });
        },
        (error: unknown) => {
          if (generation.current === request) setState({ busy: false, error: pullRequestErrorMessage(error) });
        },
      )
      .finally(() => {
        if (generation.current === request) inFlight.current = false;
      });
  }, [source]);

  return { available: !!source?.pullRequest, busy: state.busy, error: state.error, run };
}

/** The quiet toolbar action shared by the pill and narrow diff toolbar row. */
export function PullRequestActionButton({
  action,
  disabled = false,
}: {
  action: PullRequestAction;
  disabled?: boolean;
}) {
  const t = useT();
  if (!action.available) return null;
  return (
    <button
      type="button"
      className="acpmux-git-tool"
      data-tool="pull-request"
      disabled={disabled || action.busy}
      onClick={action.run}
    >
      {t("changes.createPullRequest")}
    </button>
  );
}

/** One status below either toolbar placement, so long remote errors never widen the toolbar. */
export function PullRequestActionStatus({ action }: { action: PullRequestAction }) {
  const t = useT();
  if (!action.available || (!action.busy && !action.error)) return null;
  return (
    <div className="acpmux-git-status" data-phase={action.busy ? "busy" : "failed"}>
      {action.busy ? (
        <output className="acpmux-git-status-text" aria-live="polite">
          {t("git.push.busy")}
        </output>
      ) : (
        <span className="acpmux-git-status-text" role="alert">
          {action.error}
        </span>
      )}
    </div>
  );
}

function pullRequestErrorMessage(error: unknown): string {
  if (typeof error === "string" && error.trim()) return error;
  if (error && typeof error === "object") {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message.trim()) return message;
  }
  return translate("changes.pullRequestFailed");
}
