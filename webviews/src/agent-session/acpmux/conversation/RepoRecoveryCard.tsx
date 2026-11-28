import { useEffect, useRef, useState } from "react";
import { useAutoRetry } from "../autoRetry";
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
      <div className="cv-repo-recovery" aria-live="polite">
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
      role={view.tone === "error" ? "alert" : undefined}
      aria-live={view.tone === "quiet" ? "polite" : undefined}
    >
      <span>{message}</span>
      {left !== undefined && (
        <span className="cv-repo-recovery__eta" aria-hidden="true">
          {t("cloudRepository.waitLeft", { time: left })}
        </span>
      )}
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
        (error: unknown) =>
          set(failureCode(error) === "repo.needs_github" ? { kind: "notConnected" } : { kind: "failed" }),
      );
  };
  /// Waits up to a minute for GitHub to report the install, then retries the held repository action.
  /// `again`: the card's own next wait after one that ended unconnected, with no countdown.
  const waitForGithub = (again = false) => {
    const retry = recovery.retry;
    if (!retry) return;
    set(again ? { kind: "waiting" } : { kind: "waiting", until: Date.now() + GITHUB_WAIT_MS });
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
  /// `again`: the card's own ask after the app had no link. A link found then waits for the person's
  /// Connect click, so no page opens on its own.
  const getLink = (again = false) => {
    set({ kind: "linking" });
    void request<{ connect?: { install_url?: unknown } }>("cloud.repo.local", {}).then(
      (reply) => {
        const url = githubInstallUrl(reply?.connect?.install_url);
        if (!url) return set({ kind: "noLink" });
        if (mounted.current) setFetchedUrl(url);
        if (again) return set({ kind: "idle" });
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
        // No access is an install on an organization the account may not own, or a request its owner answers later:
        // no connect to wait for (GitHub is connected already), so the card keeps its Try again for when it's done.
        if (!recovery.retry || recovery.code === "repo.no_access") return void (installUrl && open(installUrl));
        return connect(installUrl);
      case "getLink":
        return getLink();
      case "reopen":
        return void (installUrl && open(installUrl));
      case "retry":
        return attach(choice);
      case "requestAccess":
        return void open(`https://github.com/orgs/${encodeURIComponent(recovery.org ?? "")}`);
      case "choose":
        setChoice(action.repo);
        return attach(action.repo);
    }
  };

  // A missing link and an install GitHub hasn't reported yet are asked again on their own while the
  // card shows; a failure that lasts the house deadline reads as one quiet "still trying" line.
  const failed = phase.kind === "noLink" || phase.kind === "notConnected" ? phase.kind : undefined;
  const { stillTrying } = useAutoRetry(failed, () => (failed === "noLink" ? getLink(true) : waitForGithub(true)), {
    busy: phase.kind === "linking" || phase.kind === "waiting",
  });

  const view = repoRecoveryView({ ...recovery, installUrl }, phase, choice, stillTrying);
  if (!view) return null;
  return <RepoRecoveryCardView view={view} pressed={choice} onAction={onAction} />;
}
