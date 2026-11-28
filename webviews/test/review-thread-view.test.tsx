// A review thread reads like the pull request: comment bodies render their Markdown (bold, code,
// links) instead of showing raw marks, and a resolved thread's folded line says who said what,
// not only that it was resolved.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
// Markdown pulls in @pierre/diffs, which registers a custom element on import.
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    customElements: dom.window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

const thread = (resolved: boolean) => ({
  path: "src/app.ts",
  line: 12,
  side: "additions" as const,
  resolved,
  outdated: false,
  moved: false,
  comments: [{ author: "octocat", body: "**Nit:** rename `retryCount`\n\nSee the docs." }],
});

test("a comment body renders its Markdown", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ReviewThread } = await import("../src/agent-session/acpmux/changes/ReviewThread");
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<ReviewThread thread={thread(false)} />));
  const body = dom.window.document.querySelector<HTMLElement>(".acpmux-review-body")!;
  expect(body.textContent).not.toContain("**");
  expect(body.querySelector("strong")?.textContent).toBe("Nit:");
  expect(body.querySelector("code")?.textContent).toBe("retryCount");
  act(() => root.unmount());
});

test("a resolved thread's folded line names the author and opens with the comment", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ReviewThread } = await import("../src/agent-session/acpmux/changes/ReviewThread");
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<ReviewThread thread={thread(true)} />));
  const summary = dom.window.document.querySelector<HTMLElement>(".acpmux-review-thread summary")!;
  expect(summary.textContent).toContain("octocat");
  expect(summary.textContent).toContain("Nit: rename retryCount");
  act(() => root.unmount());
});

test("a suggestion fence draws as plain lines, and the folded line names no link", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ReviewThread } = await import("../src/agent-session/acpmux/changes/ReviewThread");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const body = "See [the docs](https://example.com/docs)\n\n```suggestion\nconst retries = 3;\n```";
  await act(async () =>
    root.render(<ReviewThread thread={{ ...thread(true), comments: [{ author: "octocat", body }] }} />),
  );
  const doc = dom.window.document;
  expect(doc.querySelector(".acpmux-review-body .cv-codeblock--plain")?.textContent).toContain("const retries = 3;");
  const summary = doc.querySelector<HTMLElement>(".acpmux-review-thread summary")!;
  expect(summary.textContent).toContain("octocat: See the docs");
  expect(summary.querySelector("a, button")).toBeNull();
  act(() => root.unmount());
});
