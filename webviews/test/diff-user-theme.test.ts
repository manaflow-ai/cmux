// The user's `<config dir>/diff/theme.css` (customization.md D55, rule 4) restyles an open diff tab:
// the page asks `cmux.diff.theme` at boot, applies it as the last <style> in the head, replaces it
// on every save the stream of the same name sends, and clears it on "" (the file was deleted).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;
let doc: Document;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><head></head><div id=root></div>");
  doc = dom.window.document;
  Object.assign(scope, {
    window: dom.window,
    document: doc,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

function userTheme(): HTMLStyleElement | null {
  return doc.head.querySelector<HTMLStyleElement>('style[data-cmux-user-theme="diff"]');
}

test("theme.css applies last at boot, follows every save, and clears after a delete", async () => {
  const { startPageDiffTheme } = await import("../src/diff/page");
  const { installWebviewStyles } = await import("../src/surfaces/installWebviewStyles");
  installWebviewStyles("diff", ":root { --cmux-diff-gap: 1px }", doc);
  let push: ((value: unknown) => void) | undefined;
  const calls: string[] = [];
  const page = {
    call: async (op: string) => {
      calls.push(op);
      return { themeCSS: ":root { --cmux-diff-gap: 2px }" };
    },
    subscribe: async (stream: string, onEvent: (value: unknown) => void) => {
      if (stream === "cmux.diff.theme") push = onEvent;
      return () => undefined;
    },
  };
  await startPageDiffTheme(page as never, doc);
  expect(calls).toEqual(["cmux.diff.theme"]);
  expect(userTheme()?.textContent).toBe(":root { --cmux-diff-gap: 2px }");
  expect(doc.head.lastElementChild).toBe(userTheme());

  // A surface's styles loaded later (the empty state's, git's) still sit before it.
  installWebviewStyles("git", ".git {}", doc);
  expect(doc.head.lastElementChild).toBe(userTheme());

  push?.({ themeCSS: ":root { --cmux-diff-gap: 9px }" });
  expect(userTheme()?.textContent).toBe(":root { --cmux-diff-gap: 9px }");
  expect(doc.head.querySelectorAll("style[data-cmux-user-theme]").length).toBe(1);

  push?.({ themeCSS: "" });
  expect(userTheme()?.textContent).toBe("");

  // Anything else on the stream leaves the sheet alone.
  push?.({ themeCSS: 4 });
  push?.(null);
  expect(userTheme()?.textContent).toBe("");
});

test("a host without the op or stream leaves the page unstyled and quiet", async () => {
  const { startPageDiffTheme } = await import("../src/diff/page");
  const fresh = new JSDOM("<!doctype html><head></head>").window.document;
  const unknown = Object.assign(new Error("unknown op"), { code: "cmux.protocol.unknown_op" });
  const warnings: unknown[] = [];
  const warn = console.warn;
  console.warn = (...args: unknown[]) => warnings.push(args);
  try {
    const page = {
      call: async () => {
        throw unknown;
      },
      subscribe: async () => {
        throw unknown;
      },
    };
    await startPageDiffTheme(page as never, fresh);
  } finally {
    console.warn = warn;
  }
  expect(fresh.head.querySelector("style[data-cmux-user-theme]")).toBeNull();
  expect(warnings).toEqual([]);
});
