// The builds a plan approval started off this chat (planBuild.ts): one column per build, side by side
// and stacked when narrow, each its agent, its branch, where it stands, what it changed and its first
// files, with Open and, when two agents built the same plan, Keep this one. Keeping one says so in its
// column and archives the other: its chat is archived and its worktree goes to worktree care's archive
// when idle (acpmux hub/worktree_care.rs), never deleted. The composer's Run on N agents (target
// `prompt`, 2 to 4 columns) draws the same card; its Keep also closes the others and removes their
// worktrees at once, archived first so each can be restored. Every column reserves its lines, so the card
// never changes height as diffs arrive or a build is kept: only words and colours change, together.
// The diffs are read once when the card mounts and again only when a build's turn ends.

import { useEffect, useEffectEvent, useRef, useState } from "react";
import { callNative } from "../callNative";
import { openSessionAttributes } from "../conversation/menuParts";
import { useT, type Translate } from "../i18n";
import { harnessName } from "../permissions/planBuild";
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
  /// Keeps one build and archives the rest (`chat.plan.keep`); `removeOthers` also removes their
  /// worktrees (a prompt's runs).
  keep?: (sessionId: string, buildId: string, keep: string, removeOthers: boolean) => Promise<unknown>;
  /// A gallery's diffs, drawn without a read.
  diffs?: PlanBuildReply;
};

const nativeCompare = (sessionId: string, buildId: string) => callNative("chat.plan.compare", { sessionId, buildId });
const nativeKeep = (sessionId: string, buildId: string, keep: string, removeOthers: boolean) =>
  callNative("chat.plan.keep", { sessionId, buildId, keep, ...(removeOthers ? { removeOthers } : {}) });

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
  // The build's `records` when the shown read began: a build with a newer record goes by its records.
  const [readAt, setReadAt] = useState(given ? Infinity : 0);
  const [keeping, setKeeping] = useState<string>();
  const [error, setError] = useState<string>();
  // The reads in flight answer only the newest: an older reply never overwrites a newer one.
  const reads = useRef(0);
  // The newest `compare`, read when a read starts: a new function never starts a read itself.
  const readCompare = useEffectEvent((session: string, buildId: string) => compare(session, buildId));
  useEffect(() => {
    if (given || !sessionId) return;
    const mine = ++reads.current;
    const at = build.records ?? 0;
    void readCompare(sessionId, build.buildId).then(
      (reply) => {
        const checked = planBuildReply(reply);
        if (checked && mine === reads.current) {
          setRead(checked);
          setReadAt(at);
        }
      },
      () => undefined,
    );
  }, [given, sessionId, build.buildId, build.turnsEnded, build.records, build.keptSessionId]);
  const kept = build.keptSessionId ?? read?.keptSessionId;
  const prompted = build.target === "prompt";
  const compared = build.target === "compare" || prompted;
  const removed = new Set([...(build.removed ?? []), ...(read?.removed ?? [])]);
  // A worktree Keep could not remove is never announced as gone: its column and the note say so.
  const stayed = new Map([...(build.stayed ?? []), ...(read?.stayed ?? [])].map((s) => [s.sessionId, s.error]));
  const stayedWhy = [...stayed.values()].find(Boolean) ?? "";
  const title = prompted
    ? t("planBuild.title.prompt", { n: build.builds.length })
    : t(compared ? "planBuild.title.compare" : "planBuild.title.worktree");
  const notStarted = build.failed ?? [];
  const onKeep = (child: string) => {
    if (!sessionId || keeping || kept) return;
    setKeeping(child);
    setError(undefined);
    const mine = ++reads.current;
    const at = build.records ?? 0;
    keep(sessionId, build.buildId, child, prompted).then(
      (reply) => {
        const checked = planBuildReply(reply);
        if (checked && mine === reads.current) {
          setRead(checked);
          setReadAt(at);
        }
        setKeeping(undefined);
      },
      (failure: unknown) => {
        setKeeping(undefined);
        setError(failure instanceof Error ? failure.message : String(failure));
      },
    );
  };
  // Cut to one line in a narrow chat: the whole note on hover.
  const note = error
    ? t("planBuild.keepFailed", { error })
    : kept
      ? stayed.size
        ? t("planBuild.keptNoteStayed", { error: stayedWhy })
        : removed.size
          ? t("planBuild.keptNoteRemoved")
          : t("planBuild.keptNote")
      : notStarted.length
        ? notStarted.map((f) => t("planBuild.notStarted", { harness: f.harness, error: f.error ?? "" })).join(" ")
        : "";
  return (
    <section
      className="acpmux-plan-builds"
      data-target={build.target}
      data-kept={kept ? "" : undefined}
      aria-label={title}
    >
      <header className="acpmux-plan-builds-head">
        <span className="acpmux-plan-builds-title">{title}</span>
        <span className="acpmux-plan-builds-note" role={error ? "alert" : undefined} title={note || undefined}>
          {note}
        </span>
      </header>
      <div className="acpmux-plan-builds-columns" data-count={build.builds.length}>
        {build.builds.map((child) => (
          <PlanBuildColumn
            key={child.sessionId}
            t={t}
            child={child}
            label={prompted ? runLabel(child) : undefined}
            diff={read?.builds.find((b) => b.sessionId === child.sessionId)}
            fresh={readAt >= (child.seenAt ?? 0)}
            outcome={
              !kept
                ? undefined
                : kept === child.sessionId
                  ? "kept"
                  : removed.has(child.sessionId)
                    ? "removed"
                    : stayed.has(child.sessionId)
                      ? "stayed"
                      : build.archived.includes(child.sessionId) || compared
                        ? "archived"
                        : undefined
            }
            why={stayed.get(child.sessionId)}
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

/// A prompt run's column name: its model, read from the id ("claude-opus-5-5" is "Opus 5.5",
/// "gpt-6.1-sol" is "GPT 6.1 Sol"), else its agent ("Codex"). The icon beside it names the agent.
function runLabel(child: PlanBuildChild): string | undefined {
  if (!child.model) return child.harness ? harnessName(child.harness) : undefined;
  const family = child.harness?.split(/[-/]/)[0];
  const words: string[] = [];
  for (const part of child.model.split(/[-_/\s]+/).filter(Boolean)) {
    const last = words.at(-1);
    if (/^\d+$/.test(part) && last && /^\d+(\.\d+)*$/.test(last)) words[words.length - 1] = `${last}.${part}`;
    else words.push(part);
  }
  if (words.length > 1 && words[0] === family) words.shift();
  return words
    .map((word) => (word === "gpt" ? "GPT" : /^[a-z]/.test(word) ? word[0]!.toUpperCase() + word.slice(1) : word))
    .join(" ");
}

/// A build's state: its sub-session records, or, while they still say running, acpmux's own read of
/// the chat (a turn that ended before this chat recorded the build, or a page that left it out). A
/// read that began before the build's newest record (`fresh` false) is older than it: a turn that
/// started since then is running, whatever that read said.
function liveState(child: PlanBuildChild, diff: PlanBuildDiff | undefined, fresh: boolean): PlanBuildChild["state"] {
  if (child.state !== "running" || !diff?.status || !fresh) return child.state;
  return diff.status === "done"
    ? "done"
    : diff.status === "failed"
      ? "failed"
      : diff.status === "closed"
        ? "cancelled"
        : "running";
}

function statusText(t: Translate, state: PlanBuildChild["state"]): string {
  switch (state) {
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
  label,
  diff,
  fresh,
  outcome,
  why,
  canKeep,
  keeping,
  busy,
  onOpen,
  onKeep,
}: {
  t: Translate;
  child: PlanBuildChild;
  /// The column's name, over the chat's own.
  label?: string;
  diff?: PlanBuildDiff;
  /// Whether `diff` was read after the build's newest record.
  fresh: boolean;
  outcome?: "kept" | "archived" | "removed" | "stayed";
  /// Why a closed run's worktree stayed (acpmux's reason).
  why?: string | undefined;
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
  const state = diff?.error ? "failed" : liveState(child, diff, fresh);
  return (
    <article className="acpmux-plan-builds-column" data-state={state} data-outcome={outcome}>
      <div className="acpmux-plan-builds-agent">
        <span className="acpmux-plan-builds-icon" aria-hidden>
          <SenderIcon harness={child.harness} tone={agentTone(child.sessionId)} size={14} fallback="agent.chat" />
        </span>
        <span className="acpmux-plan-builds-name">{label ?? child.name ?? child.harness ?? child.sessionId}</span>
        <span className="acpmux-plan-builds-state" title={outcome === "stayed" ? why : undefined}>
          <span className="acpmux-plan-builds-dot" aria-hidden />
          {outcome === "kept"
            ? t("planBuild.kept")
            : outcome === "archived"
              ? t("planBuild.archived")
              : outcome === "removed"
                ? t("planBuild.removed")
                : outcome === "stayed"
                  ? t("planBuild.stayed")
                  : statusText(t, state)}
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
