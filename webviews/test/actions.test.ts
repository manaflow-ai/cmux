import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { buildStageCommitCommand, copyGitApplyCommand, copyStageCommitCommand, resolveDiffNavigationURL } from "../src/actions";
import { createDiffViewerLabelResolver } from "../src/labels";

const originalGlobals = new Map<string, any>();
for (const key of ["document", "fetch", "navigator", "window"]) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(() => {
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

test("copyGitApplyCommand falls back to a React-owned textarea when clipboard API is absent", async () => {
  const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
  const textarea = dom.window.document.querySelector("textarea");
  expect(textarea).toBeTruthy();
  (globalThis as any).navigator = {};
  (globalThis as any).document = dom.window.document;
  let copied = false;
  dom.window.document.execCommand = (command: string) => {
    copied = command === "copy";
    return copied;
  };
  (globalThis as any).fetch = () => Promise.resolve(new Response("diff --git a/a b/a\n", { status: 200 }));

  const label = createDiffViewerLabelResolver(undefined);
  const message = await copyGitApplyCommand("/patch.diff", label, textarea);

  expect(message).toBe(label("copiedGitApplyCommand"));
  expect(copied).toBe(true);
  expect(textarea?.value).toContain("git apply <<'CMUX_DIFF_PATCH'");
});

test("copyGitApplyCommand falls back when clipboard writeText rejects", async () => {
  const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
  const textarea = dom.window.document.querySelector("textarea");
  expect(textarea).toBeTruthy();
  (globalThis as any).navigator = {
    clipboard: {
      writeText: () => Promise.reject(new Error("permission denied")),
    },
  };
  (globalThis as any).document = dom.window.document;
  let copied = false;
  dom.window.document.execCommand = (command: string) => {
    copied = command === "copy";
    return copied;
  };
  (globalThis as any).fetch = () => Promise.resolve(new Response("diff --git a/a b/a\n", { status: 200 }));

  const label = createDiffViewerLabelResolver(undefined);
  const message = await copyGitApplyCommand("/patch.diff", label, textarea);

  expect(message).toBe(label("copiedGitApplyCommand"));
  expect(copied).toBe(true);
});

test("copyGitApplyCommand fails when the textarea fallback cannot copy", async () => {
  const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
  const textarea = dom.window.document.querySelector("textarea");
  expect(textarea).toBeTruthy();
  (globalThis as any).navigator = {};
  (globalThis as any).document = dom.window.document;
  dom.window.document.execCommand = () => false;
  (globalThis as any).fetch = () => Promise.resolve(new Response("diff --git a/a b/a\n", { status: 200 }));

  const label = createDiffViewerLabelResolver(undefined);

  await expect(copyGitApplyCommand("/patch.diff", label, textarea)).rejects.toThrow("Clipboard copy failed");
});

test("buildStageCommitCommand quotes repo paths and avoids message delimiter collisions", () => {
  const command = buildStageCommitCommand("/tmp/cmux user's repo", "Ship review\nCMUX_COMMIT_MESSAGE\n");

  expect(command).toBe(
    "git -C '/tmp/cmux user'\"'\"'s repo' add --all && " +
      "git -C '/tmp/cmux user'\"'\"'s repo' commit -F - <<'CMUX_COMMIT_MESSAGE_1'\n" +
      "Ship review\n" +
      "CMUX_COMMIT_MESSAGE\n" +
      "CMUX_COMMIT_MESSAGE_1",
  );
});

test("copyStageCommitCommand falls back to a React-owned textarea", async () => {
  const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
  const textarea = dom.window.document.querySelector("textarea");
  expect(textarea).toBeTruthy();
  (globalThis as any).navigator = {};
  (globalThis as any).document = dom.window.document;
  let copied = false;
  dom.window.document.execCommand = (command: string) => {
    copied = command === "copy";
    return copied;
  };

  const label = createDiffViewerLabelResolver(undefined);
  const message = await copyStageCommitCommand("/tmp/repo", "Review changes", label, textarea);

  expect(message).toBe(label("copiedStageCommitCommand"));
  expect(copied).toBe(true);
  expect(textarea?.value).toContain("git -C '/tmp/repo' add --all");
  expect(textarea?.value).toContain("Review changes");
});

test("resolveDiffNavigationURL strips query and fragment for custom scheme rewrites", () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "cmux-diff-viewer://local/current",
  });
  (globalThis as any).window = dom.window;

  expect(resolveDiffNavigationURL("https://example.com/diff/target?source=worktree#file")).toBe(
    "cmux-diff-viewer://local/target",
  );
});

test("resolveDiffNavigationURL passes a root-relative URL through unchanged under the custom scheme", () => {
  // The branch picker rebases its regenerate URL to a root-relative path; under
  // the restored custom-scheme page the browser resolves it natively against the
  // token host, so it must not enter the http->scheme segment-drop rewrite (which
  // would drop the query carrying token/repo/group).
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "cmux-diff-viewer://tok/diff-g-branch.html",
  });
  (globalThis as any).window = dom.window;

  const relative = "/__cmux_diff_viewer_branch?group=g&repo=%2Ftmp%2Fr&token=abc&base=develop";
  expect(resolveDiffNavigationURL(relative)).toBe(relative);
});

test("resolveDiffNavigationURL passes a root-relative URL through unchanged under HTTP", () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "http://127.0.0.1:51234/tok/diff-g-branch.html",
  });
  (globalThis as any).window = dom.window;

  const relative = "/__cmux_diff_viewer_branch?group=g&repo=%2Ftmp%2Fr&token=abc&base=develop";
  expect(resolveDiffNavigationURL(relative)).toBe(relative);
});
