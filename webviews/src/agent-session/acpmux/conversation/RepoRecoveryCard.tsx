import { useEffect, useRef, useState } from "react";
import { postNative } from "../native";
import { NativeError } from "../nativeError";
import { Icon } from "../icons/Icon";
import { useT, type Translate } from "../i18n";
import {
  GITHUB_WAIT_MS,
  githubInstallUrl,
  repoRecoveryView,
  waitLeft,
  type RepoRecovery,
  type RepoRecoveryAction,
  type RepoRecoveryPhase,
  type RepoRecoveryText,
  type RepoRecoveryView,
} from "./repoRecoveryCardModel";

function typedFailure(value: unknown): never | void {
  if (value && typeof value === "object" && typeof (value as { code?: unknown }).code === "string")
    throw new NativeError({ code: (value as { code: string }).code });
}

function failureCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null | undefined)?.code;
  return typeof code === "string" ? code : undefined;
}

function say(t: Translate, text: RepoRecoveryText): string {
  if ("literal" in text) return text.literal;
  const values = text.values
    ? Object.fromEntries(
        Object.entries(text.values).map(([name, value]) => [name, typeof value === "string" ? value : say(t, value)]),
      )
    : undefined;
  return t(text.key, values);
}

/** A ticking "m:ss" until `until`, so the wait shows its ETA. */
function useWaitLeft(until: number | undefined): string | undefined {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (until === undefined) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [until]);
  return until === undefined ? undefined : waitLeft(until, now);
}

/** The card as drawn for one view: the message, its ETA when it waits, and its one-click steps. */
export function RepoRecoveryCardView({
  view,
  pressed,
  onAction,
}: {
  view: RepoRecoveryView;
  pressed?: string;
  onAction?: (action: RepoRecoveryAction) => void;
}) {
  const t = useT();
  const left = useWaitLeft(view.until);
  const message = say(t, view.message);
  if (view.tone === "done")
    return (
      <div className="cv-repo-recovery" role="status">
        <span className="cv-repo-recovery__chip">
          <Icon name="status.check" size={12} />
          {message}
        </span>
      </div>
    );
  const Tag = view.group ? "fieldset" : "div";
  return (
    <Tag
      className={`cv-repo-recovery${view.tone === "plain" ? "" : ` cv-repo-recovery--${view.tone}`}`}
      aria-label={view.group ? message : undefined}
      role={view.tone === "error" ? "alert" : view.tone === "quiet" ? "status" : undefined}
    >
      <span>{message}</span>
      {left !== undefined && <span className="cv-repo-recovery__eta">{t("cloudRepository.waitLeft", { time: left })}</span>}
      {view.actions.map((action) => (
        <button
          key={`${action.id}:${action.repo ?? ""}`}
          type="button"
          aria-pressed={action.id === "choose" ? pressed === action.repo : undefined}
          onClick={() => onAction?.(action)}
        >
          {say(t, action.label)}
        </button>
      ))}
    </Tag>
  );
}

export function RepoRecoveryCard({
  recovery,
  initialPhase = { kind: "idle" },
  request = postNative,
}: {
  recovery: RepoRecovery;
  /** The gallery draws later phases; the transcript always starts idle. */
  initialPhase?: RepoRecoveryPhase;
  request?: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
}) {
  const [phase, setPhase] = useState<RepoRecoveryPhase>(initialPhase);
  const [choice, setChoice] = useState<string>();
  /// A connect link fetched from the app when the tool's error carried none.
  const [fetchedUrl, setFetchedUrl] = useState<string>();
  /// Whether this card has seen GitHub connect, so the success chip can say so.
  const connected = useRef(false);
  const mounted = useRef(true);
  useEffect(
    () => () => {
      mounted.current = false;
    },
    [],
  );
  const installUrl = recovery.installUrl ?? fetchedUrl;
  const set = (next: RepoRecoveryPhase) => mounted.current && setPhase(next);

  const attach = (repo?: string) => {
    const retry = recovery.retry;
    if (!retry) return;
    set({ kind: "retrying" });
    void request(retry.action, repo ? { ...retry.args, repo } : retry.args)
      .then((value) => typedFailure(value))
      .then(
        () => set({ kind: "done", connected: connected.current }),
        (error: unknown) => set(failureCode(error) === "repo.needs_github" ? { kind: "notConnected" } : { kind: "failed" }),
      );
  };
  /// Waits up to a minute for GitHub to report the install, then retries the held repository action.
  const waitForGithub = () => {
    const retry = recovery.retry;
    if (!retry) return;
    set({ kind: "waiting", until: Date.now() + GITHUB_WAIT_MS });
    void request<{ connected?: boolean }>(retry.wait_action ?? "cloud.repo.wait_github", {
      timeout_ms: GITHUB_WAIT_MS,
    }).then(
      (reply) => {
        if (!reply?.connected) return set({ kind: "notConnected" });
        connected.current = true;
        attach(choice);
      },
      () => set({ kind: "notConnected" }),
    );
  };
  const open = (url: string) => window.open(url, "_blank", "noopener,noreferrer");
  const connect = (url: string | undefined) => {
    if (!url) return;
    open(url);
    waitForGithub();
  };
  const getLink = () => {
    set({ kind: "linking" });
    void request<{ connect?: { install_url?: unknown } }>("cloud.repo.local", {}).then(
      (reply) => {
        const url = githubInstallUrl(reply?.connect?.install_url);
        if (!url) return set({ kind: "noLink" });
        if (mounted.current) setFetchedUrl(url);
        // The page may refuse a window opened after an await; the wait offers "Open GitHub again".
        if (recovery.retry) connect(url);
        else {
          open(url);
          set({ kind: "idle" });
        }
      },
      () => set({ kind: "noLink" }),
    );
  };

  const onAction = (action: RepoRecoveryAction) => {
    switch (action.id) {
      case "connect":
        if (!recovery.retry) return void (installUrl && open(installUrl));
        return connect(installUrl);
      case "getLink":
        return getLink();
      case "reopen":
        return void (installUrl && open(installUrl));
      case "checkAgain":
        return waitForGithub();
      case "retry":
        return attach(choice);
      case "requestAccess":
        return void open(`https://github.com/orgs/${encodeURIComponent(recovery.org ?? "")}`);
      case "choose":
        setChoice(action.repo);
        return attach(action.repo);
    }
  };

  const view = repoRecoveryView({ ...recovery, installUrl }, phase, choice);
  if (!view) return null;
  return <RepoRecoveryCardView view={view} pressed={choice} onAction={onAction} />;
}
