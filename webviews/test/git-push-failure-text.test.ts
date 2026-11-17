// Push runs as `git push` would: a remote with its own push refspecs, or a branch tracking a
// branch with another name, is git's call, not a refusal of cmux's own. When git refuses, the
// Changes card says it in git's words (the session host's `extra.git_error`); only a mirror
// remote, where a push deletes the remote's other branches, keeps cmux's own line.
import { expect, test } from "bun:test";
import { KNOWN_REASONS, failureText, readWriteFailure } from "../src/agent-session/acpmux/changes/gitWrite";
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeError } from "../src/agent-session/acpmux/nativeError";

const refusal = (reason: string, extra: Record<string, unknown> = {}) =>
  new NativeError({
    code: "operation.failed",
    origin: "session_host",
    details: { operation: "git.push", reason, extra },
  });

test("a push git refused reads in git's own words, with its output under Details", () => {
  const sentence = "The upstream branch of your current branch does not match the name of your current branch.";
  const failure = readWriteFailure(
    refusal("git_failed", { git_error: sentence, output: `fatal: ${sentence}\n\n    git push origin HEAD:main` }),
  );
  expect(failure).toEqual({
    kind: "refused",
    reason: "git_failed",
    output: `fatal: ${sentence}\n\n    git push origin HEAD:main`,
    gitError: sentence,
  });
  expect(failureText("push", failure)).toBe(sentence);
  // Without git's words it is the generic line, never an empty alert.
  expect(failureText("push", readWriteFailure(refusal("git_failed")))).toBe(translate("git.push.failed"));
});

test("only a mirror remote is refused up front; refspecs and renamed upstreams are git's call", () => {
  expect(failureText("push", readWriteFailure(refusal("mirror_remote")))).toBe(translate("git.push.mirrorRemote"));
  expect(KNOWN_REASONS.push).toContain("mirror_remote");
  expect(KNOWN_REASONS.push).not.toContain("push_refspec_configured");
  expect(KNOWN_REASONS.push).not.toContain("upstream_mismatch");
});
