// Commit and Push in the changes view: the session host's `git.commit` and `git.push`
// (cmux-tui spec/resource-operations-v2.json). The page sends what its buttons do, with
// the HEAD it last read as `expected_head` so a stale view refuses with `head_moved`, and
// one idempotency key per user action: a retry of the same action sends the same key and
// params, so a commit or push whose reply was lost is reported, not repeated.
import { t, type StringKey } from "../i18n";
import { readChangeSet } from "./model";

export type GitWriteOp = "commit" | "push";

/// What Commit stages: the index as it is, or every change to tracked files (git commit -a).
/// New (untracked) files join All only when the reader ticks "Include new files".
export type CommitScope = "staged" | "all";

/// The branch state Commit and Push need, from `git.status`.
export type WriteStatus = {
  /// The chat session the status was read for (the page's client stamps it), sent with each
  /// write so the host refuses a write for a session other than the pane's.
  sessionId?: string;
  head?: string;
  branch?: string;
  upstream?: string;
  detached: boolean;
  ahead: number;
  behind: number;
};

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0);
const record = (value: unknown) =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

/// A GitStatusResult as Commit and Push read it, or undefined when it isn't one.
export function readWriteStatus(value: unknown): WriteStatus | undefined {
  const raw = record(value);
  if (!raw || typeof raw.detached !== "boolean") return undefined;
  return {
    sessionId: text(raw.session_id),
    head: text(raw.head),
    branch: text(raw.branch),
    upstream: text(raw.upstream),
    detached: raw.detached,
    ahead: count(raw.ahead),
    behind: count(raw.behind),
  };
}

/// The commit params for `message` and `scope`. Staged sends neither `paths` nor `all`, so the
/// index is committed as it is; All stages every tracked change first, and with `includeNew` the
/// untracked, nonignored files too. Staged ignores `includeNew`.
export function commitParams(
  message: string,
  scope: CommitScope,
  head: string | undefined,
  includeNew = false,
  sessionId?: string,
) {
  return {
    ...(sessionId ? { session_id: sessionId } : {}),
    message,
    ...(scope === "all" ? { all: true, ...(includeNew ? { include_untracked: true } : {}) } : {}),
    ...(head ? { expected_head: head } : {}),
  };
}

/// The session host's limit on a commit message, in UTF-8 bytes.
export const MAX_MESSAGE_BYTES = 65_536;
export const messageTooLong = (message: string) => new TextEncoder().encode(message).length > MAX_MESSAGE_BYTES;

/// The new files "Include new files" would commit, from the Uncommitted diff (`git.diff`
/// scope uncommitted lists untracked, nonignored files with status "untracked"; `git.status`
/// lists no files). `skipped` counts untracked files the diff left out to stay responsive.
export type NewFiles = { paths: string[]; skipped: number };
export function readNewFiles(value: unknown): NewFiles | undefined {
  const changeSet = readChangeSet(value, "uncommitted");
  if (!changeSet) return undefined;
  return {
    paths: changeSet.files.filter((file) => file.status === "untracked").map((file) => file.path),
    skipped: changeSet.untrackedSkipped ?? 0,
  };
}

/// The push params: the current branch to where `git push` would send it, never forced.
export function pushParams(head: string | undefined, sessionId?: string) {
  return { ...(sessionId ? { session_id: sessionId } : {}), ...(head ? { expected_head: head } : {}) };
}

/// Whether two new-file lists name the same files (order aside) and skip the same count.
export function sameNewFiles(a: NewFiles, b: NewFiles): boolean {
  if (a.skipped !== b.skipped || a.paths.length !== b.paths.length) return false;
  const names = new Set(a.paths);
  return b.paths.every((path) => names.has(path));
}

/// Stable text of params, so the same action's params compare equal.
function fingerprint(op: GitWriteOp, params: Record<string, unknown>): string {
  return JSON.stringify([op, Object.entries(params).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))]);
}

/// One key per user action. The same op with the same params after a failure is the same action
/// (Retry, or pressing Commit again): it keeps its key, so a commit or push that ran without an
/// answer is reported instead of run twice. Other params, or a success, start a new action.
/// The session host records only successes, so a refused attempt runs again under its key.
export class WriteKeys {
  private pending = new Map<GitWriteOp, { fingerprint: string; key: string }>();
  constructor(private readonly mint: () => string = () => crypto.randomUUID()) {}

  keyFor(op: GitWriteOp, params: Record<string, unknown>): string {
    const print = fingerprint(op, params);
    const pending = this.pending.get(op);
    if (pending?.fingerprint === print) return pending.key;
    const key = this.mint();
    this.pending.set(op, { fingerprint: print, key });
    return key;
  }

  succeeded(op: GitWriteOp) {
    this.pending.delete(op);
  }
}

/// How an attempt ended when it did not succeed:
/// - `refused`: the session host answered with a machine `reason` (its `details.reason`).
/// - `uncertain`: no answer (a timeout, a closed connection); it may have run. Retry asks again.
/// - `notSent`: never left the page or the bridge (no host, refused params, a cloud chat).
export type WriteFailure = {
  kind: "refused" | "uncertain" | "notSent";
  reason?: string;
  /// What git, its hooks and the remote printed, at most 16 KiB.
  output?: string;
};

export function readWriteFailure(error: unknown): WriteFailure {
  const raw = record(error);
  const code = text(raw?.code);
  const details = record(raw?.details);
  const extra = record(details?.extra);
  if (code === "operation.failed" || (code && !code.startsWith("native.") && raw?.origin !== "native")) {
    const output = text(extra?.output);
    return { kind: "refused", reason: text(details?.reason) ?? code, ...(output ? { output } : {}) };
  }
  if (code === "native.timed_out" || code === "native.failed") return { kind: "uncertain" };
  return { kind: "notSent", ...(code ? { reason: code } : {}) };
}

/// A committed MutationResult's commit, as the success line names it.
export type CommitDone = { commit: string; summary: string; filesChanged: number; replayed: boolean };
/// A pushed MutationResult: where it went, and whether the remote already had it.
export type PushDone = { upstream: string; upToDate: boolean; createdUpstream: boolean; replayed: boolean };

export function readCommitDone(result: unknown): CommitDone | undefined {
  const value = record(record(result)?.value);
  const commit = text(value?.commit);
  if (!value || !commit) return undefined;
  return {
    commit,
    summary: typeof value.summary === "string" ? value.summary : "",
    filesChanged: count(value.files_changed),
    replayed: record(result)?.replayed === true,
  };
}

export function readPushDone(result: unknown): PushDone | undefined {
  const value = record(record(result)?.value);
  const upstream = text(value?.upstream);
  if (!value || !upstream) return undefined;
  return {
    upstream,
    upToDate: value.up_to_date === true,
    createdUpstream: value.created_upstream === true,
    replayed: record(result)?.replayed === true,
  };
}

/// The localized line for a failed Commit or Push. Every reason the session host names has its
/// own text; one it adds later reads as the op's generic failure.
const COMMIT_REASONS: Record<string, StringKey> = {
  nothing_to_commit: "git.commit.nothingToCommit",
  head_moved: "git.headMoved",
  merge_in_progress: "git.commit.mergeInProgress",
  hook_failed: "git.commit.hookFailed",
  identity_missing: "git.commit.identityMissing",
  index_locked: "git.commit.indexLocked",
  path_not_found: "git.commit.pathNotFound",
};
const PUSH_REASONS: Record<string, StringKey> = {
  no_remote: "git.push.noRemote",
  push_refspec_configured: "git.push.refspecConfigured",
  mirror_remote: "git.push.mirrorRemote",
  detached_head: "git.push.detachedHead",
  branch_not_found: "git.push.branchNotFound",
  head_moved: "git.headMoved",
  rejected_non_fast_forward: "git.push.nonFastForward",
  rejected_by_remote: "git.push.rejectedByRemote",
  hook_failed: "git.push.hookFailed",
  auth_failed: "git.push.authFailed",
  network_failed: "git.push.networkFailed",
};
const SHARED_REASONS: Record<string, StringKey> = {
  not_a_repository: "git.notRepository",
  no_working_directory: "git.notRepository",
  target_not_found: "git.notRepository",
  timed_out: "git.timedOut",
  repository_changed: "git.repositoryChanged",
  store_failed: "git.storeFailed",
};

/// Refusals whose text tells the reader to refresh: the view is stale, so Refresh is offered.
export const REFRESH_REASONS = new Set([
  "head_moved",
  "path_not_found",
  "repository_changed",
  "branch_not_found",
  "native.session_changed",
]);

/// Refusals from the pane's host, before anything reached git.
const NATIVE_REASONS: Record<string, StringKey> = {
  "native.session_changed": "git.sessionChanged",
  "native.no_session_folder": "git.noSessionFolder",
};

export function failureText(op: GitWriteOp, failure: WriteFailure): string {
  if (failure.kind === "uncertain") return t(op === "commit" ? "git.commit.uncertain" : "git.push.uncertain");
  if (failure.kind === "notSent") return t(NATIVE_REASONS[failure.reason ?? ""] ?? "git.notSent");
  const reason = failure.reason ?? "";
  const key = (op === "commit" ? COMMIT_REASONS : PUSH_REASONS)[reason] ?? SHARED_REASONS[reason];
  return t(key ?? (op === "commit" ? "git.commit.failed" : "git.push.failed"));
}

/// Every machine reason the spec lists for either op, for tests that keep the texts complete.
export const KNOWN_REASONS = {
  commit: [...Object.keys(COMMIT_REASONS), ...Object.keys(SHARED_REASONS), "git_failed"],
  push: [...Object.keys(PUSH_REASONS), ...Object.keys(SHARED_REASONS), "git_failed"],
};

/// Whether Push can run: on a branch, with a commit, and either something ahead or no upstream yet.
export function canPush(status: WriteStatus | undefined): boolean {
  return !!status && !status.detached && !!status.branch && !!status.head && (!status.upstream || status.ahead > 0);
}

export const shortCommit = (commit: string) => commit.slice(0, 7);
