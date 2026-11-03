import { afterAll, afterEach, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { TurnFile } from "../src/agent-session/acpmux/diff";

let pending: Promise<void>;
let resolve: () => void;
let ready = false;
await mock.module("../src/agent-session/acpmux/conversation/EditDiffHunks", () => ({
  EditDiffHunks: () => {
    if (!ready) throw pending;
    return <div data-loaded-diff>Updated retry policy</div>;
  },
}));
const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "MutationObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    url: "https://example.test",
    pretendToBeVisual: true,
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    MutationObserver: dom.window.MutationObserver,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = document.querySelector<HTMLElement>("#root")!;
});
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
});
afterAll(() => {
  mock.restore();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
function file(lines: number): TurnFile {
  return {
    path: "src/retry.ts",
    displayPath: "src/retry.ts",
    additions: lines,
    deletions: 0,
    created: true,
    edits: [
      {
        toolId: "retry",
        numbered: true,
        hunks: [
          {
            lines: Array.from({ length: lines }, (_, index) => ({
              type: "add",
              text: `retry(${index});`,
              newLine: index + 1,
            })),
          },
        ],
      },
    ],
  };
}
async function draw(value: TurnFile) {
  ready = false;
  pending = new Promise<void>((done) => {
    resolve = done;
  });
  const { createRoot } = await import("react-dom/client");
  const { EditDiff } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  root = createRoot(host);
  await act(async () => root!.render(<EditDiff file={value} />));
}
test("a deferred inline renderer keeps its header and line placeholders until it resolves", async () => {
  await draw(file(3));
  expect(host.textContent).toContain("retry.ts");
  expect(host.querySelector('[aria-busy="true"]')).not.toBeNull();
  expect(host.querySelectorAll(".cv-edit-diff__loading-line")).toHaveLength(3);
  expect(host.querySelector(".cv-edit-diff__loading-line")?.textContent).toBe("retry(0);");
  expect(host.querySelector("[data-loaded-diff]")).toBeNull();
  await act(async () => {
    ready = true;
    resolve();
    await pending;
  });
  expect(host.querySelector('[aria-busy="true"]')).toBeNull();
  expect(host.querySelector("[data-loaded-diff]")).not.toBeNull();
  expect(host.textContent).toContain("retry.ts");
});
test("long pending edits keep the same preview and expand without waiting for the chunk", async () => {
  await draw(file(1284));
  const body = host.querySelector(".cv-edit-diff__body")!;
  expect(body.getAttribute("data-preview")).toBe("cut");
  expect(body.querySelector('[aria-busy="true"]')).not.toBeNull();
  // A huge edit draws a bounded number of lines and one block of the rest's height.
  expect(body.querySelectorAll(".cv-edit-diff__loading-line")).toHaveLength(400);
  const more = host.querySelector<HTMLButtonElement>(".cv-output-more")!;
  await act(async () => more.click());
  expect(body.getAttribute("data-preview")).toBe("all");
  expect(body.querySelectorAll(".cv-edit-diff__loading-line")).toHaveLength(400);
  expect(body.querySelector(".cv-edit-diff__loading-rest")?.getAttribute("style")).toContain("--cv-loading-lines: 884");
});

test("a known empty edit keeps its existing explanation while the chunk is pending", async () => {
  const empty = file(0);
  empty.edits[0]!.hunks = [];
  await draw(empty);
  expect(host.querySelector(".cv-edit-diff__empty")?.textContent).toBeTruthy();
  expect(host.querySelector(".cv-edit-diff__loading-lines")).toBeNull();
});

test("mid-file hunks keep a separator's room before each, as Pierre draws them", async () => {
  const value = file(0);
  value.created = false;
  value.edits[0]!.hunks = [40, 120].map((start) => ({
    lines: [0, 1].map((offset) => ({
      type: "add" as const,
      text: `retry(${start + offset});`,
      newLine: start + offset,
    })),
  }));
  await draw(value);
  const parts = [...host.querySelectorAll(".cv-edit-diff__loading-lines > *")].map((node) => node.className);
  expect(parts).toEqual([
    "cv-edit-diff__loading-sep",
    "cv-edit-diff__loading-line",
    "cv-edit-diff__loading-line",
    "cv-edit-diff__loading-sep",
    "cv-edit-diff__loading-line",
    "cv-edit-diff__loading-line",
  ]);
  expect(host.querySelector(".cv-edit-diff__loading-lines")?.getAttribute("style")).toContain("--cv-loading-digits: 4");
});
