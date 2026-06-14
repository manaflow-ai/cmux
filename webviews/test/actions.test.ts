import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { copyGitApplyCommand, resolveDiffNavigationURL } from "../src/actions";
import { adjacentDiffItemId } from "../src/App";
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

test("resolveDiffNavigationURL strips query and fragment for custom scheme rewrites", () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "cmux-diff-viewer://local/current",
  });
  (globalThis as any).window = dom.window;

  expect(resolveDiffNavigationURL("https://example.com/diff/target?source=worktree#file")).toBe(
    "cmux-diff-viewer://local/target",
  );
});

test("adjacentDiffItemId wraps next and previous file navigation", () => {
  const items = [{ id: "one" }, { id: "two" }, { id: "three" }];

  expect(adjacentDiffItemId(items, "one", 1)).toBe("two");
  expect(adjacentDiffItemId(items, "one", -1)).toBe("three");
  expect(adjacentDiffItemId(items, "three", 1)).toBe("one");
  expect(adjacentDiffItemId(items, "", 1)).toBe("one");
  expect(adjacentDiffItemId(items, "", -1)).toBe("three");
  expect(adjacentDiffItemId([], "", 1)).toBe("");
});
