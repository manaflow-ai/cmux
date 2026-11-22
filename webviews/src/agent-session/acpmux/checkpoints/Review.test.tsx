import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Checkpoint, CheckpointList } from "./protocol";
import { checkpointStrings } from "./strings";

const strings = checkpointStrings();
const dom = new JSDOM("<!doctype html><div id=root></div>");
const values = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = new Map(Object.keys(values).map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
for (const [key, value] of Object.entries(values))
  Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
afterAll(() => {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
  dom.window.close();
});
const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { CheckpointReview } = await import("./Review");
const list: CheckpointList = {
  repository_id: "repo",
  worktree_id: "worktree",
  checkpoints: [],
  next_cursor: null,
  limits: { max_bytes: 100000000, max_files: 100, max_untracked_file_bytes: 10000000 },
  candidates: [
    { path: "NOTES.md", bytes: 40, eligible: true },
    { path: "draft.txt", bytes: 25, eligible: true },
    { path: ".env", bytes: 100, eligible: false, reason: "ignored" },
  ],
};
const checkpoint: Checkpoint = {
  checkpoint_id: "checkpoint",
  repository_id: "repo",
  worktree_id: "worktree",
  ref: "refs/cmux/checkpoints/worktree/checkpoint",
  object_id: "a".repeat(40),
  revision: "1",
  complete: false,
  skipped: [{ path: "draft.txt", code: "not_selected" }],
  skipped_total: 1,
  created_at: "2026-10-02T12:00:00Z",
  expires_at: "2026-10-09T12:00:00Z",
  base: { head: "b".repeat(40), branch: "main", detached: false },
  coverage: { included: 2, omitted: 1, unavailable: 0 },
  included: { tracked: 1, untracked: 1, staged_entries: 1 },
  bytes: { logical: 80, newly_stored: 40 },
  limits: list.limits,
  pins: [],
};
const base = {
  strings,
  onCreate: (_paths: string[]) => {},
  onRefresh: () => {},
  onCopy: async (_checkpoint: Checkpoint) => {},
  onKeep: () => {},
  onRelease: () => {},
  onCancel: () => {},
};
test("Create approves only the checked eligible files and never runs merely by opening the review", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const approvals: string[][] = [];
  try {
    await act(async () =>
      root.render(createElement(CheckpointReview, { ...base, list, onCreate: (paths) => approvals.push(paths) })),
    );
    const boxes = [...container.querySelectorAll<HTMLInputElement>("input")];
    expect(boxes.map((box) => [box.checked, box.disabled])).toEqual([
      [true, false],
      [true, false],
      [false, true],
    ]);
    expect(approvals).toEqual([]);
    await act(async () => boxes[1]!.click());
    await act(async () => container.querySelector<HTMLButtonElement>("button[type=submit]")!.click());
    expect(approvals).toEqual([["NOTES.md"]]);
  } finally {
    await act(async () => root.unmount());
  }
});
test("partial capture displays omissions and failed copying never claims success", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(
        createElement(CheckpointReview, {
          ...base,
          record: checkpoint,
          onCopy: async () => {
            throw new Error("clipboard unavailable");
          },
        }),
      ),
    );
    expect(container.querySelector("[data-complete=false]")?.textContent).toBe(strings.partial);
    expect(container.textContent).toContain("draft.txt");
    expect(container.textContent).toContain(strings.notSelected);
    expect(container.querySelector("details")?.open).toBe(true);
    const copy = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.textContent === strings.copyReference,
    )!;
    await act(async () => {
      copy.click();
      await Promise.resolve();
    });
    expect(copy.textContent).toBe(strings.copyReference);
    expect(container.textContent).toContain(strings.manualRetention);
  } finally {
    await act(async () => root.unmount());
  }
});
