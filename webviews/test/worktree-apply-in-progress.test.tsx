// Apply to main checkout shows only where it works (ceremony audit, Leo 2026-11-17): while a merge,
// rebase, cherry-pick or revert is stopped partway in the worktree (`git.status` in_progress), Apply
// is off, in the popover and the native menu alike, instead of answering "Finish the merge or rebase
// in this worktree first".
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { worktreeOf } = await import("../src/agent-session/acpmux/header/worktreePillModel");
const { useWorktreeOps } = await import("../src/agent-session/acpmux/header/worktreeOps");
type Ops = ReturnType<typeof useWorktreeOps>;

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const status = (extra: Record<string, unknown> = {}) => ({
  branch: "feature",
  base: "main",
  detached: false,
  worktree: { main_root: "/repo" },
  ...extra,
});

test("worktreeOf reads in_progress from git.status", () => {
  expect(worktreeOf(status())?.inProgress).toBeUndefined();
  expect(worktreeOf(status({ in_progress: "rebase" }))?.inProgress).toBe(true);
});

test("Apply is off while the worktree is mid-merge or mid-rebase, and on once it ends", async () => {
  const applied: string[] = [];
  let ops!: Ops;
  function Probe({ value }: { value: unknown }) {
    ops = useWorktreeOps(worktreeOf(value), "/repo-wt", async (key) => {
      applied.push(key);
      return { value: { files: [] } };
    });
    return null;
  }
  await act(async () => root.render(<Probe value={status({ in_progress: "merge" })} />));
  expect(ops.apply?.enabled).toBe(false);
  await act(async () => ops.apply!.run());
  expect(applied).toEqual([]);
  expect(ops.messages).toEqual([]);

  await act(async () => root.render(<Probe value={status()} />));
  expect(ops.apply?.enabled).toBe(true);
  await act(async () => ops.apply!.run());
  expect(applied).toHaveLength(1);
});
