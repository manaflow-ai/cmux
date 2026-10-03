import { expect, test } from "bun:test";
import { t } from "../i18n";
import {
  canPush,
  commitParams,
  failureText,
  KNOWN_REASONS,
  messageTooLong,
  sameNewFiles,
  readNewFiles,
  REFRESH_REASONS,
  pushParams,
  readCommitDone,
  readPushDone,
  readWriteFailure,
  readWriteStatus,
  WriteKeys,
} from "./gitWrite";

const HEAD = "4be1c2e9a0f1b2c3d4e5f60718293a4b5c6d7e8f";

test("Staged commits the index as it is; All is tracked files only unless new files are included", () => {
  expect(commitParams("Fix", "staged", HEAD)).toEqual({ message: "Fix", expected_head: HEAD });
  // git commit -a: an untracked .env stays out.
  expect(commitParams("Fix", "all", HEAD)).toEqual({ message: "Fix", all: true, expected_head: HEAD });
  expect(commitParams("Fix", "all", HEAD, true)).toEqual({
    message: "Fix",
    all: true,
    include_untracked: true,
    expected_head: HEAD,
  });
  // Staged ignores the new-files box.
  expect(commitParams("Fix", "staged", HEAD, true)).toEqual({ message: "Fix", expected_head: HEAD });
  expect(messageTooLong("a".repeat(65_536))).toBe(false);
  expect(messageTooLong("é".repeat(32_769))).toBe(true);
  expect(
    readNewFiles({
      files: [
        { path: "a.ts", status: "modified" },
        { path: ".env", status: "untracked" },
      ],
      untracked_skipped: 2,
    }),
  ).toEqual({ paths: [".env"], skipped: 2 });
  expect(readNewFiles({})).toBeUndefined();
  expect([...REFRESH_REASONS].sort()).toEqual([
    "branch_not_found",
    "head_moved",
    "native.session_changed",
    "path_not_found",
    "repository_changed",
  ]);
  // Before the first commit there is no HEAD to expect.
  expect(commitParams("Init", "staged", undefined)).toEqual({ message: "Init" });
  expect(pushParams(HEAD)).toEqual({ expected_head: HEAD });
  expect(pushParams(undefined)).toEqual({});
});

test("the same action keeps its key until it succeeds; other params start a new action", () => {
  let minted = 0;
  const keys = new WriteKeys(() => `k${++minted}`);
  const params = commitParams("Fix", "staged", HEAD);
  const first = keys.keyFor("commit", params);
  // A retry after a lost reply, or Commit pressed again with the same message and HEAD.
  expect(keys.keyFor("commit", { ...params })).toBe(first);
  expect(keys.keyFor("commit", { expected_head: HEAD, message: "Fix" })).toBe(first);
  // Push is its own action.
  expect(keys.keyFor("push", pushParams(HEAD))).not.toBe(first);
  // Another message is another action.
  const second = keys.keyFor("commit", commitParams("Fix more", "staged", HEAD));
  expect(second).not.toBe(first);
  // After a success, the same params are a new action.
  keys.succeeded("commit");
  expect(keys.keyFor("commit", commitParams("Fix more", "staged", HEAD))).not.toBe(second);
});

test("a failure is the session host's reason, a lost reply, or a request never sent", () => {
  const refusal = {
    code: "operation.failed",
    origin: "session_host",
    details: {
      operation: "git.push",
      reason: "rejected_non_fast_forward",
      extra: { message: "behind", output: "! [rejected] main -> main (fetch first)" },
    },
  };
  expect(readWriteFailure(refusal)).toEqual({
    kind: "refused",
    reason: "rejected_non_fast_forward",
    output: "! [rejected] main -> main (fetch first)",
  });
  expect(readWriteFailure({ code: "idempotency.conflict", origin: "session_host" })).toEqual({
    kind: "refused",
    reason: "idempotency.conflict",
  });
  expect(readWriteFailure({ code: "native.timed_out", origin: "native" })).toEqual({ kind: "uncertain" });
  expect(readWriteFailure({ code: "native.failed", origin: "native" })).toEqual({ kind: "uncertain" });
  expect(readWriteFailure({ code: "native.not_connected", origin: "native" }).kind).toBe("notSent");
  expect(readWriteFailure({ code: "native.invalid_request", origin: "native" }).kind).toBe("notSent");
  expect(readWriteFailure(new Error("This chat runs on another machine")).kind).toBe("notSent");
});

test("every reason the spec names has its own localized text", () => {
  for (const op of ["commit", "push"] as const) {
    const generic = failureText(op, { kind: "refused", reason: "git_failed" });
    expect(generic).toBe(t(op === "commit" ? "git.commit.failed" : "git.push.failed"));
    for (const reason of KNOWN_REASONS[op]) {
      if (reason === "git_failed") continue;
      expect(failureText(op, { kind: "refused", reason })).not.toBe(generic);
    }
  }
  // The spec's lists, so a reason the session host adds shows up here first.
  expect(new Set(KNOWN_REASONS.commit)).toEqual(
    new Set([
      "not_a_repository",
      "no_working_directory",
      "target_not_found",
      "nothing_to_commit",
      "head_moved",
      "merge_in_progress",
      "hook_failed",
      "identity_missing",
      "index_locked",
      "path_not_found",
      "timed_out",
      "repository_changed",
      "store_failed",
      "git_failed",
    ]),
  );
  expect(new Set(KNOWN_REASONS.push)).toEqual(
    new Set([
      "not_a_repository",
      "no_working_directory",
      "target_not_found",
      "no_remote",
      "push_refspec_configured",
      "mirror_remote",
      "detached_head",
      "branch_not_found",
      "head_moved",
      "rejected_non_fast_forward",
      "rejected_by_remote",
      "hook_failed",
      "auth_failed",
      "network_failed",
      "timed_out",
      "repository_changed",
      "store_failed",
      "git_failed",
    ]),
  );
  expect(failureText("push", { kind: "refused", reason: "head_moved" })).toBe(t("git.headMoved"));
  expect(failureText("commit", { kind: "uncertain" })).toBe(t("git.commit.uncertain"));
  expect(failureText("push", { kind: "notSent" })).toBe(t("git.notSent"));
  // The host's own refusals have their own text.
  expect(failureText("push", readWriteFailure({ code: "native.session_changed", origin: "native" }))).toBe(
    t("git.sessionChanged"),
  );
  expect(failureText("commit", readWriteFailure({ code: "native.no_session_folder", origin: "native" }))).toBe(
    t("git.noSessionFolder"),
  );
  expect(pushParams(HEAD, "s1")).toEqual({ session_id: "s1", expected_head: HEAD });
  expect(commitParams("Fix", "staged", HEAD, false, "s1")).toEqual({
    session_id: "s1",
    message: "Fix",
    expected_head: HEAD,
  });
  expect(sameNewFiles({ paths: ["a", "b"], skipped: 0 }, { paths: ["b", "a"], skipped: 0 })).toBe(true);
  expect(sameNewFiles({ paths: ["a"], skipped: 0 }, { paths: ["a", "b"], skipped: 0 })).toBe(false);
});

test("status, results and whether Push can run", () => {
  const status = readWriteStatus({
    root: "/repo",
    branch: "feat",
    detached: false,
    head: HEAD,
    upstream: "origin/feat",
    ahead: 2,
    behind: 0,
  });
  expect(status).toEqual({ head: HEAD, branch: "feat", upstream: "origin/feat", detached: false, ahead: 2, behind: 0 });
  expect(canPush(status)).toBe(true);
  expect(canPush({ ...status!, ahead: 0 })).toBe(false);
  // A branch without an upstream can be published even with nothing counted ahead.
  expect(canPush({ ...status!, upstream: undefined, ahead: 0 })).toBe(true);
  expect(canPush({ ...status!, detached: true, branch: undefined })).toBe(false);
  expect(canPush({ ...status!, head: undefined })).toBe(false);
  expect(readWriteStatus({ branch: "x" })).toBeUndefined();
  expect(
    readCommitDone({
      value: { root: "/r", commit: HEAD, summary: "Fix", files_changed: 3, additions: 1, deletions: 0 },
      replayed: true,
    }),
  ).toEqual({ commit: HEAD, summary: "Fix", filesChanged: 3, replayed: true });
  expect(
    readPushDone({
      value: { upstream: "origin/feat", up_to_date: true, created_upstream: false, pushed_commit: HEAD },
      replayed: false,
    }),
  ).toEqual({ upstream: "origin/feat", upToDate: true, createdUpstream: false, replayed: false });
  expect(readCommitDone({ value: {} })).toBeUndefined();
});
