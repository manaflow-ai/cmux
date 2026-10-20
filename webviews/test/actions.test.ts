import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { buildGitApplyCommand, copyGitApplyCommand, resolveDiffNavigationURL } from "../src/actions";
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
  expect(textarea?.value).toMatch(/^git apply <<'CMUX_DIFF_PATCH_[0-9a-f]{24}'\n/);
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

// Splits copied command text the way an interactive shell sees pasted input:
// CRLF, bare CR, and LF all end a line.
function shellLines(command: string): string[] {
  return command.split(/\r\n|\r|\n/);
}

function heredocDelimiter(command: string): string {
  const match = /^git apply <<'([^']+)'\n/.exec(command);
  expect(match).toBeTruthy();
  return match![1];
}

function expectDelimiterOnlyClosesAtEnd(command: string) {
  const delimiter = heredocDelimiter(command);
  const lines = shellLines(command);
  expect(lines[lines.length - 1]).toBe(delimiter);
  expect(lines.slice(1, -1)).not.toContain(delimiter);
}

async function copyThroughTextarea(patchText: string): Promise<{ message: string; value: string; copied: boolean }> {
  const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
  const textarea = dom.window.document.querySelector("textarea");
  (globalThis as any).navigator = {};
  (globalThis as any).document = dom.window.document;
  let copied = false;
  dom.window.document.execCommand = (command: string) => {
    copied = command === "copy";
    return copied;
  };
  (globalThis as any).fetch = () => Promise.resolve(new Response(patchText, { status: 200 }));
  const message = await copyGitApplyCommand("/patch.diff", createDiffViewerLabelResolver(undefined), textarea);
  return { message, value: textarea!.value, copied };
}

test("copyGitApplyCommand keeps a bare-CR delimiter line inside the heredoc", async () => {
  const payload = [
    "diff --git a/a b/a",
    "+x\rCMUX_DIFF_PATCH\rtouch /tmp/cmux-should-not-run\rCMUX_DIFF_PATCH_1\rgit apply <<'CMUX_DIFF_PATCH'",
    "",
  ].join("\n");

  const { value } = await copyThroughTextarea(payload);

  expectDelimiterOnlyClosesAtEnd(value);
  for (const line of shellLines(payload)) {
    expect(line).not.toBe(heredocDelimiter(value));
  }
});

test("buildGitApplyCommand skips a random delimiter that the patch already contains on a CR-split line", () => {
  const tokens = ["aaaa", "bbbb"];
  const patch = "diff --git a/a b/a\n+x\rCMUX_DIFF_PATCH_aaaa\recho injected\n";

  const command = buildGitApplyCommand(patch, () => tokens.shift()!);

  expect(heredocDelimiter(command)).toBe("CMUX_DIFF_PATCH_bbbb");
  expectDelimiterOnlyClosesAtEnd(command);
});

test("buildGitApplyCommand fails closed when no unique delimiter can be chosen", () => {
  const patch = "diff --git a/a b/a\n+CMUX_DIFF_PATCH_aaaa\n";

  expect(() => buildGitApplyCommand(patch, () => "aaaa")).toThrow();
});

test("buildGitApplyCommand uses an unpredictable delimiter", () => {
  const patch = "diff --git a/a b/a\n";

  expect(heredocDelimiter(buildGitApplyCommand(patch))).not.toBe(heredocDelimiter(buildGitApplyCommand(patch)));
});

for (const [name, character] of [
  ["NUL", "\u0000"],
  ["ESC", "\u001b"],
  ["form feed", "\u000c"],
  ["vertical tab", "\u000b"],
  ["DEL", "\u007f"],
  ["NEL (C1)", "\u0085"],
  ["CSI (C1)", "\u009b"],
] as const) {
  test(`copyGitApplyCommand refuses a patch containing ${name} on every clipboard path`, async () => {
    const dom = new JSDOM("<!doctype html><html><body><textarea></textarea></body></html>");
    const textarea = dom.window.document.querySelector("textarea");
    const writes: string[] = [];
    (globalThis as any).navigator = {
      clipboard: {
        writeText: (text: string) => {
          writes.push(text);
          return Promise.resolve();
        },
      },
    };
    (globalThis as any).document = dom.window.document;
    let execCalls = 0;
    dom.window.document.execCommand = () => {
      execCalls += 1;
      return true;
    };
    (globalThis as any).fetch = () =>
      Promise.resolve(new Response(`diff --git a/a b/a\n+x${character}[201~echo injected\n`, { status: 200 }));

    await expect(
      copyGitApplyCommand("/patch.diff", createDiffViewerLabelResolver(undefined), textarea),
    ).rejects.toThrow("Patch contains control characters");
    expect(writes).toEqual([]);
    expect(execCalls).toBe(0);
    expect(textarea!.value).toBe("");
  });
}

test("copyGitApplyCommand still copies a normal CRLF patch with tabs", async () => {
  const patch = "diff --git a/a.txt b/a.txt\r\n--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1 +1 @@\r\n-\told\r\n+\tnew\r\n";
  const writes: string[] = [];
  (globalThis as any).navigator = {
    clipboard: {
      writeText: (text: string) => {
        writes.push(text);
        return Promise.resolve();
      },
    },
  };
  (globalThis as any).fetch = () => Promise.resolve(new Response(patch, { status: 200 }));
  const label = createDiffViewerLabelResolver(undefined);

  const message = await copyGitApplyCommand("/patch.diff", label, null);

  expect(message).toBe(label("copiedGitApplyCommand"));
  expect(writes).toHaveLength(1);
  const delimiter = heredocDelimiter(writes[0]);
  expect(writes[0]).toBe(`git apply <<'${delimiter}'\n${patch}${delimiter}`);
  expectDelimiterOnlyClosesAtEnd(writes[0]);

  const fallback = await copyThroughTextarea(patch);
  expect(fallback.copied).toBe(true);
  expectDelimiterOnlyClosesAtEnd(fallback.value);
});
