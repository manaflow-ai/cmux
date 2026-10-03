// The changes view's Commit and Push: reads `git.status` for the HEAD and ahead count, runs one
// write at a time, and keeps the outcome until the next write or a dismiss. A stale reply never
// shows: each status read and each write is numbered, and only the latest settles.
import { useCallback, useEffect, useRef, useState } from "react";
import { t } from "../i18n";
import type { ChangesSource } from "./model";
import {
  canPush,
  commitParams,
  failureText,
  pushParams,
  readCommitDone,
  readNewFiles,
  readPushDone,
  readWriteFailure,
  readWriteStatus,
  REFRESH_REASONS,
  shortCommit,
  WriteKeys,
  type CommitScope,
  type GitWriteOp,
  type NewFiles,
  type WriteFailure,
  type WriteStatus,
} from "./gitWrite";

export type GitWriteState =
  | { phase: "busy"; op: GitWriteOp }
  | { phase: "done"; op: GitWriteOp; text: string }
  | { phase: "failed"; op: GitWriteOp; text: string; failure: WriteFailure; canRetry: boolean; canRefresh: boolean };

export type GitWrite = {
  /// Commit and Push are offered only when the source can run them.
  available: boolean;
  status?: WriteStatus;
  statusFailed: boolean;
  state?: GitWriteState;
  commit: (message: string, scope: CommitScope, includeNew: boolean) => Promise<boolean>;
  /// The untracked files "Include new files" would commit, from the Uncommitted diff.
  listNewFiles: () => Promise<NewFiles>;
  push: () => Promise<boolean>;
  /// Runs the failed write again with its params and key.
  retry: () => void;
  /// Reads the status again, reloads the scope and drops the outcome (a stale view, or a
  /// status read that failed).
  refresh: () => void;
  dismiss: () => void;
};

/// `onChanged` runs after each write that succeeds (and after Refresh, with no op), so the view
/// reloads its scope. The status is read when the view opens, after each write and on Refresh;
/// not on a scope reload, so Commit and Push keep the HEAD the reader saw and a view that went
/// stale refuses with `head_moved` instead of acting on a state nobody looked at.
/// `keys` is the session's key ring, kept by the page across a close and reopen of the view, so
/// a retry after an uncertain write still sends its key.
export function useGitWrite(
  source: ChangesSource | undefined,
  onChanged: (op?: GitWriteOp) => void,
  keys?: WriteKeys,
): GitWrite {
  const available = !!(source?.status && source.commit && source.push);
  const [status, setStatus] = useState<WriteStatus>();
  const [statusFailed, setStatusFailed] = useState(false);
  const [state, setState] = useState<GitWriteState>();
  const statusRef = useRef<WriteStatus | undefined>(undefined);
  const reads = useRef(0);
  const writes = useRef(0);
  const busy = useRef(false);
  const last = useRef<{ op: GitWriteOp; params: Record<string, unknown> } | undefined>(undefined);
  const [ownKeys] = useState(() => new WriteKeys());
  const keyRing = keys ?? ownKeys;

  const readStatus = useCallback(async (): Promise<WriteStatus | undefined> => {
    if (!source?.status) return undefined;
    const read = ++reads.current;
    try {
      const next = readWriteStatus(await source.status());
      if (read === reads.current) {
        statusRef.current = next;
        setStatus(next);
        setStatusFailed(!next);
      }
      return next;
    } catch {
      if (read === reads.current) {
        statusRef.current = undefined;
        setStatus(undefined);
        setStatusFailed(true);
      }
      return undefined;
    }
  }, [source]);

  // The status is read when the view opens.
  useEffect(() => {
    if (available) void readStatus();
  }, [available, readStatus]);

  const run = useCallback(
    async (op: GitWriteOp, params: Record<string, unknown>): Promise<boolean> => {
      const send = op === "commit" ? source?.commit : source?.push;
      if (!send || busy.current) return false;
      busy.current = true;
      const write = ++writes.current;
      last.current = { op, params };
      setState({ phase: "busy", op });
      const idempotency_key = keyRing.keyFor(op, params);
      try {
        const result = await send({ ...params, idempotency_key });
        keyRing.succeeded(op);
        if (write === writes.current) setState({ phase: "done", op, text: doneText(op, result) });
        await readStatus();
        onChanged(op);
        return true;
      } catch (error) {
        const failure = readWriteFailure(error);
        if (write === writes.current)
          setState({
            phase: "failed",
            op,
            failure,
            text: failureText(op, failure),
            canRetry: failure.kind === "uncertain" || RETRYABLE.has(failure.reason ?? ""),
            canRefresh: REFRESH_REASONS.has(failure.reason ?? ""),
          });
        return false;
      } finally {
        busy.current = false;
      }
    },
    [source, readStatus, onChanged, keyRing],
  );

  const commit = useCallback(
    async (message: string, scope: CommitScope, includeNew: boolean) => {
      const current = statusRef.current ?? (await readStatus());
      return run("commit", commitParams(message, scope, current?.head, includeNew, current?.sessionId));
    },
    [run, readStatus],
  );

  const push = useCallback(async () => {
    let current = statusRef.current ?? (await readStatus());
    // A status that says nothing to push may be stale: read it once more before refusing.
    // `expected_head` still guards the push against a branch that moves after this read.
    if (!canPush(current)) current = await readStatus();
    if (!canPush(current)) {
      const failure: WriteFailure = {
        kind: "refused",
        reason: current?.detached ? "detached_head" : "nothing_to_push",
      };
      setState({
        phase: "failed",
        op: "push",
        failure,
        text: current?.detached ? t("git.push.detachedHead") : current ? t("git.push.nothing") : t("git.statusFailed"),
        canRetry: false,
        canRefresh: !current,
      });
      return false;
    }
    return run("push", pushParams(current?.head, current?.sessionId));
  }, [run, readStatus]);

  const retry = useCallback(() => {
    if (last.current) void run(last.current.op, last.current.params);
  }, [run]);
  const refresh = useCallback(() => {
    setState(undefined);
    void readStatus();
    onChanged();
  }, [readStatus, onChanged]);
  const dismiss = useCallback(() => setState(undefined), []);
  const listNewFiles = useCallback(async () => {
    const files = source ? readNewFiles(await source.diff("uncommitted")) : undefined;
    if (!files) throw new Error("No new file list");
    return files;
  }, [source]);

  return { available, status, statusFailed, state, commit, listNewFiles, push, retry, refresh, dismiss };
}

function doneText(op: GitWriteOp, result: unknown): string {
  if (op === "commit") {
    const done = readCommitDone(result);
    return done
      ? t("git.commit.done", { commit: shortCommit(done.commit), summary: done.summary })
      : t("git.commit.doneBare");
  }
  const done = readPushDone(result);
  if (!done) return t("git.push.doneBare");
  return t(done.upToDate ? "git.push.upToDate" : "git.push.done", { upstream: done.upstream });
}

/// Refusals that can pass on their own, so Retry is offered: a timeout, the network, a lock,
/// cmux failing to record a result it may have reached.
const RETRYABLE = new Set(["timed_out", "network_failed", "index_locked", "store_failed"]);
