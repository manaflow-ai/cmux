// Remove from the worktree pill (cx-lyqio.5, Codex/Conductor style): a worktree chat's cleanup.
// Remove takes the worktree and the branch New Worktree made (`git.worktree.remove`). Work found
// nowhere else stops it inline, and only "Remove anyway" discards that work, never a single click.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The popover places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const WORKTREE = "/Users/me/.cmux/worktrees/app/fix-login";
const MAIN = "/Users/me/app";
const status = async () => ({
  root: WORKTREE,
  branch: "cmux/fix-login",
  base: "main",
  detached: false,
  worktree: { main_root: MAIN },
});
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const doc = () => dom.window.document;
const popover = () => doc().querySelector(".acpmux-worktree-status");
const button = (name: string) =>
  [...doc().querySelectorAll<HTMLButtonElement>(".acpmux-worktree-status button")].find(
    (item) => item.textContent?.trim() === name,
  );
const click = async (name: string) => {
  await act(async () => button(name)!.click());
  await settle();
};
const failure = (reason: string, extra: Record<string, unknown> = {}) =>
  Object.assign(new Error("The commit or push did not go through."), {
    code: "operation.failed",
    details: { reason, extra },
  });

type Remove = (key: string, discard: boolean) => Promise<unknown>;

async function render(onRemoveWorktree?: Remove) {
  const root = createRoot(doc().getElementById("root")!);
  await act(async () =>
    root.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        summary={null}
        menu={() => []}
        folder={WORKTREE}
        readStatus={status}
        onApplyWorktree={async () => ({ value: { main_root: MAIN, files: [] }, replayed: false })}
        onRemoveWorktree={onRemoveWorktree}
      />,
    ),
  );
  await settle();
  await act(async () => doc().querySelector<HTMLButtonElement>("button.acpmux-header-worktree")!.click());
  await settle();
  return root;
}

test("Remove takes a clean worktree and its branch in one click", async () => {
  const calls: [string, boolean][] = [];
  const root = await render(async (key, discard) => {
    calls.push([key, discard]);
    return {
      value: { root: WORKTREE, main_root: MAIN, branch: "cmux/fix-login", branch_deleted: true },
      replayed: false,
    };
  });
  try {
    await click("Remove worktree");
    expect(calls).toHaveLength(1);
    expect(calls[0]![1]).toBe(false);
    expect(popover()?.querySelector("output")?.textContent).toBe("Removed the worktree and its branch cmux/fix-login");
    // Nothing is left to apply or remove.
    expect(button("Apply to main checkout")).toBeUndefined();
    expect(button("Remove worktree")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("uncommitted work stops Remove inline; only Remove anyway discards it", async () => {
  const calls: [string, boolean][] = [];
  const root = await render(async (key, discard) => {
    calls.push([key, discard]);
    if (!discard) throw failure("uncommitted_changes", { files: ["a.txt", "notes.md"], count: 2 });
    return {
      value: { root: WORKTREE, main_root: MAIN, branch: "cmux/fix-login", branch_deleted: true },
      replayed: false,
    };
  });
  try {
    await click("Remove worktree");
    expect(popover()?.querySelector("[role=alert]")?.textContent).toBe(
      "The worktree has uncommitted changes to a.txt, notes.md",
    );
    // Keep leaves everything as it was.
    await click("Keep");
    expect(popover()?.querySelector("[role=alert]")).toBeNull();
    expect(calls).toHaveLength(1);
    await click("Remove worktree");
    await click("Remove anyway");
    expect(calls).toHaveLength(3);
    expect(calls.map(([, discard]) => discard)).toEqual([false, false, true]);
    // Discarding is another action than the refused one: its own key.
    expect(calls[2]![0]).not.toBe(calls[1]![0]);
    expect(popover()?.querySelector("output")?.textContent).toBe("Removed the worktree and its branch cmux/fix-login");
  } finally {
    await act(async () => root.unmount());
  }
});

test("commits found nowhere else stop Remove too, and a kept branch is said", async () => {
  const root = await render(async (_key, discard) => {
    if (!discard) throw failure("unpushed_commits", { branch: "cmux/fix-login", count: 3 });
    return {
      value: { root: WORKTREE, main_root: MAIN, branch: "cmux/fix-login", branch_deleted: false },
      replayed: false,
    };
  });
  try {
    await click("Remove worktree");
    expect(popover()?.querySelector("[role=alert]")?.textContent).toBe(
      "cmux/fix-login has commits found on no other branch or remote",
    );
    await click("Remove anyway");
    expect(popover()?.querySelector("output")?.textContent).toBe("Removed the worktree");
  } finally {
    await act(async () => root.unmount());
  }
});

test("any other refusal offers no discard", async () => {
  const root = await render(async () => {
    throw failure("git_failed");
  });
  try {
    await click("Remove worktree");
    expect(popover()?.querySelector("[role=alert]")?.textContent).toBe("Couldn't remove the worktree");
    expect(button("Remove anyway")).toBeUndefined();
    expect(button("Remove worktree")).toBeDefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat without a session has nothing to remove yet", async () => {
  const root = await render(undefined);
  try {
    expect(popover()?.textContent).toContain("cmux/fix-login");
    expect(button("Remove worktree")).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a Remove anyway that failed retries as the same action, never as a plain Remove", async () => {
  const calls: [string, boolean][] = [];
  const answers: (() => Promise<unknown>)[] = [
    async () => {
      throw failure("uncommitted_changes", { files: ["a.txt"], count: 1 });
    },
    async () => {
      throw Object.assign(new Error("timed out"), { code: "native.timed_out" });
    },
    async () => ({
      value: { root: WORKTREE, main_root: MAIN, branch: "cmux/fix-login", branch_deleted: true },
      replayed: true,
    }),
  ];
  const root = await render(async (key, discard) => {
    calls.push([key, discard]);
    return answers[calls.length - 1]!();
  });
  try {
    await click("Remove worktree");
    await click("Remove anyway");
    expect(popover()?.querySelector("[role=alert]")?.textContent).toBe("Couldn't remove the worktree");
    // The retry is the discard again, under its key, so the host replays it.
    expect(button("Remove worktree")).toBeUndefined();
    await click("Remove anyway");
    expect(calls.map(([, discard]) => discard)).toEqual([false, true, true]);
    expect(calls[2]![0]).toBe(calls[1]![0]);
    expect(popover()?.querySelector("output")?.textContent).toBe("Removed the worktree and its branch cmux/fix-login");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Apply and Remove never run at once", async () => {
  let finish: (value: unknown) => void = () => {};
  const root = createRoot(doc().getElementById("root")!);
  await act(async () =>
    root.render(
      <ChatHeaderTools
        onTerminal={() => {}}
        onBrowser={() => {}}
        summary={null}
        menu={() => []}
        folder={WORKTREE}
        readStatus={status}
        onApplyWorktree={() => new Promise((resolve) => (finish = resolve))}
        onRemoveWorktree={async () => ({ value: { root: WORKTREE, main_root: MAIN }, replayed: false })}
      />,
    ),
  );
  await settle();
  await act(async () => doc().querySelector<HTMLButtonElement>("button.acpmux-header-worktree")!.click());
  await settle();
  try {
    await click("Apply to main checkout");
    expect(button("Remove worktree")?.disabled).toBe(true);
    await act(async () => finish({ value: { main_root: MAIN, files: ["a.txt"] }, replayed: false }));
    await settle();
    expect(button("Remove worktree")?.disabled).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});
