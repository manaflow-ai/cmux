// The builds a plan approval started off this chat (planBuild.ts): one column per build, side by side
// and stacked when narrow, each its agent, its branch, where it stands, what it changed and its first
// files, with Open and, when two agents built the same plan, Keep this one. Keeping one says so in its
// column and archives the other: its chat is archived and its worktree goes to worktree care's archive
// when idle (acpmux hub/worktree_care.rs), never deleted. Every column reserves its lines, so the card
// never changes height as diffs arrive or a build is kept: only words and colours change, together.
// The diffs are read once when the card mounts and again only when a build's turn ends.

import { useEffect, useEffectEvent, useRef, useState } from "react";
import { callNative } from "../callNative";
import { openSessionAttributes } from "../conversation/menuParts";
import { useT, type Translate } from "../i18n";
import { SenderIcon } from "../subagents/SenderIcon";
import { agentTone } from "../subagents/agentTones";
import {
  SHOWN_FILES,
  planBuildReply,
  type PlanBuild,
  type PlanBuildChild,
  type PlanBuildDiff,
  type PlanBuildReply,
} from "./planBuild";
import "./planBuild.css";

export type PlanBuildCardProps = {
  build: PlanBuild;
  /// The chat the plan was approved in: the builds' parent.
  sessionId?: string;
  /// Opens a build's chat.
  onOpen(sessionId: string): void;
  /// Reads the builds' diffs (`chat.plan.compare`); the gallery passes a fixture.
  compare?: (sessionId: string, buildId: string) => Promise<unknown>;
  /// Keeps one build and archives the rest (`chat.plan.keep`).
  keep?: (sessionId: string, buildId: string, keep: string) => Promise<unknown>;
  /// A gallery's diffs, drawn without a read.
  diffs?: PlanBuildReply;
};

const nativeCompare = (sessionId: string, buildId: string) => callNative("chat.plan.compare", { sessionId, buildId });
const nativeKeep = (sessionId: string, buildId: string, keep: string) =>
  callNative("chat.plan.keep", { sessionId, buildId, keep });

export function PlanBuildCard({
  build,
  sessionId,
  onOpen,
  compare = nativeCompare,
  keep = nativeKeep,
  diffs: given,
}: PlanBuildCardProps) {
  const t = useT();
  const [read, setRead] = useState<PlanBuildReply | undefined>(given);
  const [keeping, setKeeping] = useState<string>();
  const [error, setError] = useState<string>();
  // The reads in flight answer only the newest: an older reply never overwrites a newer one.
  const reads = useRef(0);
  // The newest `compare`, read when a read starts: a new function never starts a read itself.
  const readCompare = useEffectEvent((session: string, buildId: string) => compare(session, buildId));
  useEffect(() => {
    if (given || !sessionId) return;
    const mine = ++reads.current;
    void readCompare(sessionId, build.buildId).then(
      (reply) => {
        const checked = planBuildReply(reply);
        if (checked && mine === reads.current) setRead(checked);
      },
      () => undefined,
    );
  }, [given, sessionId, build.buildId, build.turnsEnded, build.keptSessionId]);
  const kept = build.keptSessionId ?? read?.keptSessionId;
  const compared = build.target === "compare";
  const notStarted = build.failed ?? [];
  const onKeep = (child: string) => {
    if (!sessionId || keeping || kept) return;
    setKeeping(child);
    setError(undefined);
    const mine = ++reads.current;
    keep(sessionId, build.buildId, child).then(
      (reply) => {
        const checked = planBuildReply(reply);
        if (checked && mine === reads.current) setRead(checked);
        setKeeping(undefined);
      },
      (failure: unknown) => {
        setKeeping(undefined);
        setError(failure instanceof Error ? failure.message : String(failure));
      },
    );
  };
  return (
    <section
      className="acpmux-plan-builds"
      data-target={build.target}
      data-kept={kept ? "" : undefined}
      aria-label={t(compared ? "planBuild.title.compare" : "planBuild.title.worktree")}
    >
      <header className="acpmux-plan-builds-head">
        <span className="acpmux-plan-builds-title">
          {t(compared ? "planBuild.title.compare" : "planBuild.title.worktree")}
        </span>
        <span className="acpmux-plan-builds-note" role={error ? "alert" : undefined}>
          {error
            ? t("planBuild.keepFailed", { error })
            : kept
              ? t("planBuild.keptNote")
              : notStarted.length
                ? notStarted
                    .map((f) => t("planBuild.notStarted", { harness: f.harness, error: f.error ?? "" }))
                    .join(" ")
                : ""}
        </span>
      </header>
      <div className="acpmux-plan-builds-columns" data-count={build.builds.length}>
        {build.builds.map((child) => (
          <PlanBuildColumn
            key={child.sessionId}
            t={t}
            child={child}
            diff={read?.builds.find((b) => b.sessionId === child.sessionId)}
            outcome={
              !kept
                ? undefined
                : kept === child.sessionId
                  ? "kept"
                  : build.archived.includes(child.sessionId) || compared
                    ? "archived"
                    : undefined
            }
            canKeep={compared && build.builds.length > 1 && !kept && Boolean(sessionId)}
            keeping={keeping === child.sessionId}
            busy={keeping !== undefined}
            onOpen={onOpen}
            onKeep={onKeep}
          />
        ))}
      </div>
    </section>
  );
}

/// A build's state: its sub-session records, or, while they still say running, acpmux's own read of
/// the chat (a turn that ended before this chat recorded the build, or a page that left it out).
function liveState(child: PlanBuildChild, diff: PlanBuildDiff | undefined): PlanBuildChild["state"] {
  if (child.state !== "running" || !diff?.status) return child.state;
  return diff.status === "done"
    ? "done"
    : diff.status === "failed"
      ? "failed"
      : diff.status === "closed"
        ? "cancelled"
        : "running";
}

function statusText(t: Translate, child: PlanBuildChild, diff: PlanBuildDiff | undefined): string {
  if (diff?.error) return t("planBuild.status.failed");
  switch (liveState(child, diff)) {
    case "running":
      return t("planBuild.status.running");
    case "failed":
      return t("planBuild.status.failed");
    case "cancelled":
      return t("planBuild.status.stopped");
    default:
      return t("planBuild.status.done");
  }
}

function PlanBuildColumn({
  t,
  child,
  diff,
  outcome,
  canKeep,
  keeping,
  busy,
  onOpen,
  onKeep,
}: {
  t: Translate;
  child: PlanBuildChild;
  diff?: PlanBuildDiff;
  outcome?: "kept" | "archived";
  canKeep: boolean;
  keeping: boolean;
  busy: boolean;
  onOpen(sessionId: string): void;
  onKeep(sessionId: string): void;
}) {
  const branch = diff?.branch ?? child.branch;
  const files = diff?.files ?? [];
  const shown = files.slice(0, SHOWN_FILES);
  const total = files.length + (diff?.moreFiles ?? 0);
  const more = total - shown.length;
  const state = diff?.error ? "failed" : liveState(child, diff);
  return (
    <article className="acpmux-plan-builds-column" data-state={state} data-outcome={outcome}>
      <div className="acpmux-plan-builds-agent">
        <span className="acpmux-plan-builds-icon" aria-hidden>
          <SenderIcon harness={child.harness} tone={agentTone(child.sessionId)} size={14} fallback="agent.chat" />
        </span>
        <span className="acpmux-plan-builds-name">{child.name ?? child.harness ?? child.sessionId}</span>
        <span className="acpmux-plan-builds-state">
          <span className="acpmux-plan-builds-dot" aria-hidden />
          {outcome === "kept"
            ? t("planBuild.kept")
            : outcome === "archived"
              ? t("planBuild.archived")
              : statusText(t, child, diff)}
        </span>
      </div>
      <div className="acpmux-plan-builds-branch" title={branch}>
        {branch ?? " "}
      </div>
      <div className="acpmux-plan-builds-stats">
        {diff ? (
          <>
            <span className="acpmux-plan-builds-added">+{diff.added}</span>
            <span className="acpmux-plan-builds-removed">−{diff.removed}</span>
            <span className="acpmux-plan-builds-files">{t("planBuild.files", { n: total })}</span>
          </>
        ) : (
          " "
        )}
      </div>
      <ul className="acpmux-plan-builds-list" aria-label={t("planBuild.changedFiles")}>
        {diff?.error ? (
          <li className="acpmux-plan-builds-empty">{diff.error}</li>
        ) : diff && !files.length ? (
          <li className="acpmux-plan-builds-empty">{t("planBuild.noChanges")}</li>
        ) : (
          shown.map((file) => (
            <li key={file.path} title={file.path}>
              <span className="acpmux-plan-builds-path">{file.path}</span>
              <span className="acpmux-plan-builds-added">+{file.added}</span>
              <span className="acpmux-plan-builds-removed">−{file.removed}</span>
            </li>
          ))
        )}
        {more > 0 && <li className="acpmux-plan-builds-more">{t("planBuild.moreFiles", { n: more })}</li>}
      </ul>
      <div className="acpmux-plan-builds-actions">
        <button
          type="button"
          className="acpmux-plan-builds-open"
          {...openSessionAttributes(child.sessionId)}
          onClick={() => onOpen(child.sessionId)}
        >
          {t("planBuild.open")}
        </button>
        {canKeep && (
          <button
            type="button"
            className="acpmux-plan-builds-keep"
            disabled={busy || state === "running"}
            aria-busy={keeping || undefined}
            onClick={() => onKeep(child.sessionId)}
          >
            {t("planBuild.keep")}
          </button>
        )}
      </div>
    </article>
  );
}
