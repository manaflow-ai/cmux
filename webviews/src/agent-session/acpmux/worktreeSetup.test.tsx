// A new worktree chat's setup line: New Worktree remembers the setup the host started, the line
// follows it with `git.worktree.setup` from the last `output_end`, stops reading at a final state
// or a failed read, and draws each state (a failure with its exit code, its output open).
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { newWorktree } from "./startFolderModel";
import {
  WorktreeSetupLine,
  followWorktreeSetup,
  forgetWorktreeSetup,
  rememberWorktreeSetup,
  type SetupView,
} from "./worktreeSetup";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function mount(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const flush = () => act(async () => {});

/** A scheduler the test ticks by hand: the page clock's shape. */
function manualClock() {
  const clock = { tick: () => {}, every: (): number | null => null, stopped: false };
  const repeat = (_name: string, tick: () => void, every: () => number | null) => {
    clock.tick = tick;
    clock.every = every;
    return () => {
      clock.stopped = true;
    };
  };
  return { clock, repeat };
}

const reply = (state: string, output: string, start: number, end: number, extra: Record<string, unknown> = {}) => ({
  root: "/w/fix",
  recipe: { setup: "bun install", run: null, teardown: null, include: [], repository: {}, files: [] },
  run: { state, output, output_start: String(start), output_end: String(end), setup: "bun install", ...extra },
});

test("the line reads from the last output_end, joins the output, and stops at a final state", async () => {
  const answers = [reply("running", "one\n", 0, 4), reply("succeeded", "two\n", 4, 8, { exit_code: 0 })];
  const calls: Record<string, unknown>[] = [];
  const views: SetupView[] = [];
  const { clock, repeat } = manualClock();
  const callNative = async (method: string, params?: Record<string, unknown>) => {
    expect(method).toBe("git.worktree.setup");
    calls.push(params ?? {});
    return answers.shift();
  };
  followWorktreeSetup(callNative, "/w/fix", (view) => views.push(view), repeat);
  await flush();
  expect(calls).toEqual([{ path: "/w/fix", since: "0" }]);
  expect(clock.every()).toBe(1000);
  clock.tick();
  await flush();
  expect(calls[1]).toEqual({ path: "/w/fix", since: "4" });
  expect(views.at(-1)?.output).toBe("one\ntwo\n");
  expect(views.at(-1)?.run.state).toBe("succeeded");
  // Final: no next read is scheduled, and a stray tick reads nothing.
  expect(clock.every()).toBeNull();
  clock.tick();
  await flush();
  expect(calls).toHaveLength(2);
});

test("a host that cannot answer stops the reads after the first", async () => {
  let calls = 0;
  const views: SetupView[] = [];
  const { clock, repeat } = manualClock();
  const stop = followWorktreeSetup(
    async () => {
      calls += 1;
      throw Object.assign(new Error("unknown"), { code: "unsupported" });
    },
    "/w/fix",
    (view) => views.push(view),
    repeat,
  );
  await flush();
  // The line ends instead of spinning on what the create reply said.
  expect(views.map((view) => view.run.state)).toEqual(["interrupted"]);
  expect(clock.every()).toBeNull();
  clock.tick();
  await flush();
  expect(calls).toBe(1);
  stop();
  expect(clock.stopped).toBe(true);
});

test("New Worktree remembers the setup the host started, under the folder the host spells", async () => {
  const used: string[] = [];
  const result = await newWorktree(
    async (method) =>
      method === "git.worktree.create"
        ? { value: { root: "/w/fix", branch: "cmux/fix", setup: { state: "copying", port: 40_010 } } }
        : { status: "ok", cwd: "/private/w/fix" },
    "/src/app",
    (folder) => used.push(folder),
  );
  expect(used).toEqual(["/private/w/fix"]);
  expect(result.setup).toEqual({ state: "copying", port: 40_010 });
  // Nothing to follow when the recipe is empty.
  expect(rememberWorktreeSetup("/w/none", { state: "none", port: 40_020 })).toBeUndefined();
  forgetWorktreeSetup("/w/fix");
  forgetWorktreeSetup("/private/w/fix");
});

test("a failed setup says its exit code and port, opens its output, and offers Dismiss", async () => {
  const element = mount();
  let dismissed = false;
  const view: SetupView = {
    run: {
      state: "failed",
      port: 40_010,
      setup: "bun install",
      exitCode: 1,
      startedMs: 1000,
      finishedMs: 5100,
      output: "error: lockfile is frozen\n",
      outputStart: "0",
      outputEnd: "26",
    },
    output: "error: lockfile is frozen\n",
    read: true,
  };
  await act(async () => {
    root = createRoot(element);
    root.render(<WorktreeSetupLine view={view} onDismiss={() => (dismissed = true)} />);
  });
  const line = element.querySelector<HTMLElement>(".acpmux-worktree-setup")!;
  expect(line.dataset.state).toBe("failed");
  expect(line.textContent).toContain("Setup script failed");
  expect(line.textContent).toContain("exit 1");
  expect(line.textContent).toContain("Port 40010");
  expect(line.textContent).toContain("4.1s");
  expect(line.querySelector(".acpmux-worktree-setup__drawer")!.getAttribute("data-open")).toBe("true");
  expect(line.querySelector(".acpmux-worktree-setup__output")!.textContent).toContain("lockfile is frozen");
  const dismiss = [...line.querySelectorAll("button")].find((button) => button.textContent === "Dismiss")!;
  await act(async () => dismiss.click());
  expect(dismissed).toBe(true);
});

test("Creating worktree… and a running setup draw in the same row, with no Dismiss while it runs", async () => {
  const element = mount();
  await act(async () => {
    root = createRoot(element);
    root.render(<WorktreeSetupLine creating />);
  });
  expect(element.querySelector(".acpmux-worktree-creating")!.textContent).toContain("Creating worktree");
  const running: SetupView = {
    run: {
      state: "running",
      setup: "bun install",
      startedMs: Date.now(),
      output: "",
      outputStart: "0",
      outputEnd: "0",
    },
    output: "",
    read: true,
  };
  await act(async () => root!.render(<WorktreeSetupLine view={running} onDismiss={() => {}} />));
  const line = element.querySelector<HTMLElement>(".acpmux-worktree-setup")!;
  expect(line.textContent).toContain("Running setup script");
  expect(line.querySelector(".acpmux-worktree-setup__drawer")!.getAttribute("data-open")).toBe("false");
  expect([...line.querySelectorAll("button")].some((button) => button.textContent === "Dismiss")).toBe(false);
});
