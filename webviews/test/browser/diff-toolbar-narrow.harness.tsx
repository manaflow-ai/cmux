// Browser harness for test/diff-toolbar-narrow.test.ts: the real diff viewer as the chat header's ±
// opens it, beside the chat, on a host that serves the git ops (Commit and Push in the toolbar).
// `?picker` adds the base picker ("HEAD -> main") the page host shows for a branch diff; `&long` makes
// its base a long branch name.
import "../../src/pages/shared/desktop";
import "../../src/styles.css";
import { diffViewerLabelsFor } from "../../src/labels";
import { setDiffPageClientForTesting } from "../../src/diff/page";
import { DIFF_GIT_OPS } from "../../src/diff-viewer/git";
import { mountDiffSurface } from "../../src/surfaces/diffSurface";

const patch = `diff --git a/src/upload.sh b/src/upload.sh\n--- a/src/upload.sh\n+++ b/src/upload.sh\n@@ -1,3 +1,3 @@\n #!/bin/sh\n-retries=3\n+retries=5\n done\n`;
const patchURL = URL.createObjectURL(new Blob([patch], { type: "text/plain" }));
setDiffPageClientForTesting({
  call: async (op: string) =>
    op === DIFF_GIT_OPS.status
      ? { head: "0123456789abcdef0123456789abcdef01234567", branch: "main", ahead: 0, detached: false }
      : { files: [] },
  subscribe: async () => () => {},
} as never);
const config = document.createElement("script");
config.id = "cmux-diff-viewer-config";
config.type = "application/json";
config.textContent = JSON.stringify({
  ops: Object.values(DIFF_GIT_OPS),
  payload: {
    title: "uploader",
    patchURL,
    sessionSource: { kind: "branch", repoRoot: "/home/dev/uploader", baseRef: "main" },
    layout: "unified",
    layoutSource: "explicit",
    labels: diffViewerLabelsFor("en"),
    ...(new URLSearchParams(location.search).has("picker")
      ? {
          branchPicker: {
            repoRoot: "/home/dev/uploader",
            headRef: "HEAD",
            currentRef: new URLSearchParams(location.search).has("long")
              ? "origin/feature/some-very-long-branch-name"
              : "main",
            currentReason: "",
            confidence: "high",
            aheadBehind: null,
            refsURL: "/refs",
            regenerateURLTemplate: "/regenerate/{ref}",
          },
        }
      : {}),
  },
});
document.head.append(config);
void mountDiffSurface(document.getElementById("root")!);
