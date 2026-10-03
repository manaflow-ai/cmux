import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
class Inert {
  observe() {}
  unobserve() {}
  disconnect() {}
}
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: Inert,
  ResizeObserver: Inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../DiffPanel");
const { t } = await import("../i18n");
const { WriteKeys } = await import("./gitWrite");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 50 && !done(); tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};
const click = async (element: Element | null) => {
  expect(element).not.toBeNull();
  await act(async () => {
    element!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
};
const type = async (field: Element | null, value: string) => {
  expect(field).not.toBeNull();
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(field, value);
    field!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
};
const statusLine = () => doc.querySelector(".acpmux-git-status");
const alertText = () => statusLine()?.querySelector('[role="alert"]')?.textContent ?? "";
const statusButton = (label: string) =>
  [...doc.querySelectorAll(".acpmux-git-status button")].find((button) => button.textContent === label) ?? null;
const HEAD = "4be1c2e9a0f1b2c3d4e5f60718293a4b5c6d7e8f";

type Call = Record<string, unknown>;
/// The Uncommitted diff of a repository with one untracked, unignored `.env`.
const uncommitted = {
  root: "/repo",
  files: [
    { path: "src/a.ts", status: "modified", additions: 1, deletions: 0 },
    { path: ".env", status: "untracked", additions: 1, deletions: 0 },
    { path: "notes/todo.md", status: "untracked", additions: 3, deletions: 0 },
  ],
};
function fakeSource({
  status = { detached: false, branch: "feat", head: HEAD, upstream: "origin/feat", ahead: 1, behind: 0 } as
    | Call
    | (() => Promise<Call>),
  commit = [] as (() => Promise<unknown>)[],
  push = [] as (() => Promise<unknown>)[],
  diff = uncommitted as unknown,
} = {}) {
  const calls = { status: 0, commit: [] as Call[], push: [] as Call[], diff: [] as string[] };
  return {
    calls,
    source: {
      diff: (scope: string) => (
        calls.diff.push(scope),
        Promise.resolve(scope === "uncommitted" ? diff : { files: [] })
      ),
      status: () => (calls.status++, typeof status === "function" ? status() : Promise.resolve(status)),
      commit: (params: Call) => (calls.commit.push(params), commit.shift()!()),
      push: (params: Call) => (calls.push.push(params), push.shift()!()),
    },
  };
}
const committed = (replayed = false) =>
  Promise.resolve({
    value: {
      root: "/repo",
      commit: "abcdef0123456789",
      summary: "Fix upload",
      files_changed: 1,
      additions: 2,
      deletions: 0,
    },
    generation: "g",
    revision: 1,
    replayed,
  });
const render = (source: unknown, extra: Record<string, unknown> = {}) =>
  act(async () =>
    root.render(createElement(DiffPanel, { files: [], onClose: () => {}, source: source as never, ...extra })),
  );

test("Commit sends the message and the HEAD the view read; a lost reply's Retry sends the same key", async () => {
  const { calls, source } = fakeSource({
    commit: [() => Promise.reject({ code: "native.timed_out", origin: "native" }), () => committed(true)],
  });
  await render(source);
  await settle(() => calls.status > 0);
  await click(doc.querySelector('[data-tool="commit"]'));
  const message = doc.querySelector(".acpmux-git-message");
  expect(doc.activeElement).toBe(message);
  await type(message, "Fix upload");
  await click(doc.querySelector(".acpmux-git-primary"));
  await settle(() => statusLine()?.getAttribute("data-phase") === "failed");
  expect(alertText()).toBe(t("git.commit.uncertain"));
  const retry = [...doc.querySelectorAll(".acpmux-git-status button")].find((b) => b.textContent === t("git.retry"));
  await click(retry ?? null);
  await settle(() => statusLine()?.getAttribute("data-phase") === "done");
  // Busy and done are announced by the status region, which stayed mounted.
  expect(statusLine()?.querySelector("output")?.textContent).toBe("Committed abcdef0: Fix upload");
  expect(calls.commit).toHaveLength(2);
  expect(calls.commit[0]).toEqual({
    message: "Fix upload",
    expected_head: HEAD,
    idempotency_key: calls.commit[0]!.idempotency_key,
  });
  expect(typeof calls.commit[0]!.idempotency_key).toBe("string");
  expect(calls.commit[1]).toEqual(calls.commit[0]!);
  // The form closes after the commit, and the status is read again.
  expect(doc.querySelector(".acpmux-git-form")).toBeNull();
  expect(calls.status).toBeGreaterThan(1);
});

test("All commits tracked changes only: an untracked .env is not sent; Escape closes the form", async () => {
  let closed = 0;
  const { calls, source } = fakeSource({ commit: [() => committed()] });
  await render(source, { onClose: () => closed++ });
  await settle(() => calls.status > 0);
  await click(doc.querySelector('[data-tool="commit"]'));
  await type(doc.querySelector(".acpmux-git-message"), "Add files");
  await click(doc.querySelector('.acpmux-git-scope input[value="all"]'));
  // "Include new files" shows with All and starts off.
  const includeNew = doc.querySelector<HTMLInputElement>('.acpmux-git-include-new input[type="checkbox"]');
  expect(includeNew?.checked).toBe(false);
  await click(doc.querySelector(".acpmux-git-primary"));
  await settle(() => calls.commit.length > 0 && statusLine()?.getAttribute("data-phase") === "done");
  // git commit -a: no include_untracked, so the session host leaves .env untracked.
  expect(calls.commit[0]).toEqual({
    message: "Add files",
    all: true,
    expected_head: HEAD,
    idempotency_key: calls.commit[0]!.idempotency_key,
  });
  expect(calls.diff).toEqual([]);
  await click(doc.querySelector('[data-tool="commit"]'));
  const field = doc.querySelector(".acpmux-git-message")!;
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(doc.querySelector(".acpmux-git-form")).toBeNull();
  expect(closed).toBe(0);
});

test("Include new files lists the untracked files from the Uncommitted diff, then sends include_untracked", async () => {
  const { calls, source } = fakeSource({ commit: [() => committed()] });
  await render(source);
  await settle(() => calls.status > 0);
  await click(doc.querySelector('[data-tool="commit"]'));
  await type(doc.querySelector(".acpmux-git-message"), "Add files");
  await click(doc.querySelector('.acpmux-git-scope input[value="all"]'));
  await click(doc.querySelector('.acpmux-git-include-new input[type="checkbox"]'));
  await settle(() => doc.querySelectorAll(".acpmux-git-new-files li").length > 0);
  expect(calls.diff).toEqual(["uncommitted"]);
  expect([...doc.querySelectorAll(".acpmux-git-new-files li")].map((item) => item.textContent)).toEqual([
    ".env",
    "notes/todo.md",
  ]);
  await click(doc.querySelector(".acpmux-git-primary"));
  await settle(() => calls.commit.length > 0);
  expect(calls.commit[0]).toMatchObject({ message: "Add files", all: true, include_untracked: true });
});

test("new files the diff could not list block Include new files; an over-long message says so", async () => {
  const { calls, source } = fakeSource({ diff: { ...uncommitted, untracked_skipped: 4 } });
  await render(source);
  await settle(() => calls.status > 0);
  await click(doc.querySelector('[data-tool="commit"]'));
  await type(doc.querySelector(".acpmux-git-message"), "é".repeat(32_769));
  expect(doc.querySelector(".acpmux-git-form")?.textContent).toContain(t("git.commit.tooLong"));
  expect((doc.querySelector(".acpmux-git-primary") as HTMLButtonElement).disabled).toBe(true);
  await type(doc.querySelector(".acpmux-git-message"), "Add files");
  await click(doc.querySelector('.acpmux-git-scope input[value="all"]'));
  await click(doc.querySelector('.acpmux-git-include-new input[type="checkbox"]'));
  await settle(() => doc.querySelectorAll(".acpmux-git-new-files li").length > 0);
  expect(doc.querySelector(".acpmux-git-new-files")?.textContent).toContain(t("git.commit.newFilesSkipped", { n: 4 }));
  expect((doc.querySelector(".acpmux-git-primary") as HTMLButtonElement).disabled).toBe(true);
  expect(calls.commit).toEqual([]);
});

test("a failed status read says so with Refresh, which reads it again", async () => {
  let fail = true;
  const { calls, source } = fakeSource({
    status: () =>
      fail
        ? Promise.reject(new Error("Not a git repository"))
        : Promise.resolve({
            detached: false,
            branch: "feat",
            head: HEAD,
            upstream: "origin/feat",
            ahead: 1,
            behind: 0,
          }),
  });
  await render(source);
  await settle(() => alertText() === t("git.statusFailed"));
  fail = false;
  await click(statusButton(t("git.refresh")));
  await settle(() => calls.status === 2 && statusLine()?.getAttribute("data-phase") === "idle");
  expect(alertText()).toBe("");
  expect((doc.querySelector('[data-tool="push"]') as HTMLButtonElement).disabled).toBe(false);
});

test("Push reads a stale status again before saying there is nothing to push", async () => {
  const ahead = [0, 2];
  const { calls, source } = fakeSource({
    status: () =>
      Promise.resolve({
        detached: false,
        branch: "feat",
        head: HEAD,
        upstream: "origin/feat",
        ahead: ahead.shift() ?? 2,
        behind: 0,
      }),
    push: [
      () =>
        Promise.resolve({
          value: { upstream: "origin/feat", up_to_date: false, created_upstream: false, pushed_commit: HEAD },
          replayed: false,
        }),
    ],
  });
  await render(source);
  await settle(() => calls.status === 1 && (doc.querySelector('[data-tool="push"]') as HTMLButtonElement)?.disabled);
  // The palette's Push arrives while the view's status says nothing is ahead.
  await render(source, { gitIntent: { op: "push", nonce: 1 } });
  await settle(() => calls.push.length === 1);
  // Reads: when the view opened, again before refusing, and after the push.
  expect(calls.status).toBe(3);
  expect(calls.push[0]).toMatchObject({ expected_head: HEAD });
});

test("a view opened again after a lost reply retries with the session's key", async () => {
  const keys = new WriteKeys();
  const { calls, source } = fakeSource({
    push: [
      () => Promise.reject({ code: "native.timed_out", origin: "native" }),
      () =>
        Promise.resolve({
          value: { upstream: "origin/feat", up_to_date: true, created_upstream: false, pushed_commit: HEAD },
          replayed: true,
        }),
    ],
  });
  const pushEnabled = () => (doc.querySelector('[data-tool="push"]') as HTMLButtonElement | null)?.disabled === false;
  await render(source, { writeKeys: keys });
  await settle(pushEnabled);
  await click(doc.querySelector('[data-tool="push"]'));
  await settle(() => statusLine()?.getAttribute("data-phase") === "failed");
  await act(async () => root.unmount());
  root = createRoot(doc.getElementById("root")!);
  await render(source, { writeKeys: keys });
  await settle(pushEnabled);
  await click(doc.querySelector('[data-tool="push"]'));
  await settle(() => calls.push.length === 2 && statusLine()?.getAttribute("data-phase") === "done");
  expect(calls.push[1]).toEqual(calls.push[0]!);
});

test("HEAD moved since the view was read: the line says so and Refresh reads the status again", async () => {
  const { calls, source } = fakeSource({
    commit: [
      () =>
        Promise.reject({
          code: "operation.failed",
          origin: "session_host",
          details: { operation: "git.commit", reason: "head_moved", extra: { message: "HEAD is now 1234" } },
        }),
    ],
  });
  await render(source);
  await settle(() => calls.status > 0);
  await click(doc.querySelector('[data-tool="commit"]'));
  await type(doc.querySelector(".acpmux-git-message"), "Fix");
  await click(doc.querySelector(".acpmux-git-primary"));
  await settle(() => statusLine()?.getAttribute("data-phase") === "failed");
  expect(alertText()).toBe(t("git.headMoved"));
  const before = calls.status;
  await click(statusButton(t("git.refresh")));
  await settle(() => calls.status > before);
  expect(statusLine()?.getAttribute("data-phase")).toBe("idle");
});

test("Push shows how far the branch is ahead, and a rejected push says why with git's output", async () => {
  const { calls, source } = fakeSource({
    status: { detached: false, branch: "feat", head: HEAD, upstream: "origin/feat", ahead: 2, behind: 1 },
    push: [
      () =>
        Promise.reject({
          code: "operation.failed",
          origin: "session_host",
          details: {
            operation: "git.push",
            reason: "rejected_non_fast_forward",
            extra: { message: "behind", output: "! [rejected] feat -> feat (fetch first)" },
          },
        }),
    ],
  });
  await render(source);
  await settle(
    () => doc.querySelector('[data-tool="push"]')?.getAttribute("aria-label") === t("git.push.ahead.other", { n: 2 }),
  );
  const push = doc.querySelector('[data-tool="push"]') as HTMLButtonElement;
  expect(push.disabled).toBe(false);
  expect(push.textContent).toContain("↑2");
  await click(push);
  await settle(() => statusLine()?.getAttribute("data-phase") === "failed");
  expect(calls.push).toEqual([{ expected_head: HEAD, idempotency_key: calls.push[0]!.idempotency_key }]);
  expect(alertText()).toBe(t("git.push.nonFastForward"));
  expect(statusLine()?.querySelector(".acpmux-git-output pre")?.textContent).toContain("fetch first");
  // No Retry: pushing again cannot pass until the branch is pulled.
  expect([...doc.querySelectorAll(".acpmux-git-status button")].some((b) => b.textContent === t("git.retry"))).toBe(
    false,
  );
});

test("Push is disabled with nothing ahead; the palette's Push runs once per request", async () => {
  const idle = fakeSource({
    status: { detached: false, branch: "feat", head: HEAD, upstream: "origin/feat", ahead: 0, behind: 0 },
  });
  await render(idle.source);
  await settle(() => idle.calls.status > 0);
  await settle(() => doc.querySelector('[data-tool="push"]')?.getAttribute("aria-label") === t("git.push.nothing"));
  expect((doc.querySelector('[data-tool="push"]') as HTMLButtonElement).disabled).toBe(true);
  await act(async () => root.unmount());
  root = createRoot(doc.getElementById("root")!);
  const pushed = () =>
    Promise.resolve({
      value: { upstream: "origin/feat", up_to_date: false, created_upstream: false, pushed_commit: HEAD },
      replayed: false,
    });
  const { calls, source } = fakeSource({ push: [pushed, pushed] });
  await render(source, { gitIntent: { op: "push", nonce: 1 } });
  await settle(() => statusLine()?.getAttribute("data-phase") === "done");
  expect(statusLine()?.textContent).toContain(t("git.push.done", { upstream: "origin/feat" }));
  await render(source, { gitIntent: { op: "push", nonce: 1 } });
  expect(calls.push).toHaveLength(1);
  await render(source, { gitIntent: { op: "push", nonce: 2 } });
  await settle(() => calls.push.length === 2);
  // A new request is a new action, with its own key.
  expect(calls.push[1]!.idempotency_key).not.toBe(calls.push[0]!.idempotency_key);
});
