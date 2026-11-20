import { expect, test } from "bun:test";
import { PullRequestActionView, type PullRequestAction } from "./pullRequestActionView";
import type { HeaderPullRequest } from "./headerState";

const pr: HeaderPullRequest = {
  number: 1,
  url: "https://github.com/example/repo/pull/1",
  title: "PR",
  state: "open",
  headSha: "a".repeat(40),
  review: "review_required",
  mergeable: "unknown",
  checks: { state: "passing", passed: 1, total: 1 },
  checkList: [],
};

test("leaving and returning aborts the old request before its prompt can be sent", async () => {
  const old = new PullRequestActionView(pr);
  old.activate();
  let finish!: (value: HeaderPullRequest) => void;
  let sent = 0;
  const action: PullRequestAction = async (_, __, signal) => {
    const result = await new Promise<HeaderPullRequest>((resolve) => {
      finish = resolve;
    });
    if (!signal.aborted) sent++;
    return result;
  };
  const pending = old.invoke("state", action, "failed");
  old.dispose();
  const returned = new PullRequestActionView(pr);
  returned.activate();
  finish(pr);
  await pending;
  expect(sent).toBe(0);
  expect(returned.generation).not.toBe(old.generation);
  expect(old.snapshot().head).toBeUndefined();
  returned.dispose();
});

test("refresh uses authoritative head and checks for the next action; double clicks are ignored", async () => {
  const view = new PullRequestActionView(pr);
  view.activate();
  const fresh = { ...pr, headSha: "b".repeat(40), checks: { state: "failing", passed: 0, total: 1 } };
  await view.invoke("state", async () => fresh, "failed");
  expect(view.snapshot().head).toEqual(fresh);
  let finish!: (value: HeaderPullRequest) => void;
  const seen: string[] = [];
  const run: PullRequestAction = async (target) => {
    seen.push(target.headSha!);
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const first = view.invoke("fixChecks", run, "failed");
  await view.invoke("fixChecks", run, "failed");
  expect(seen).toEqual([fresh.headSha]);
  finish(fresh);
  await first;
  expect(view.snapshot().busy).toBeUndefined();
  view.dispose();
});

test("a disposed request cannot overwrite a reactivated view", async () => {
  const view = new PullRequestActionView(pr);
  view.activate();
  let fail!: (reason: Error) => void;
  const old = view.invoke(
    "state",
    () =>
      new Promise((_, reject) => {
        fail = reject;
      }),
    "failed",
  );
  view.dispose();
  view.activate();
  await view.invoke("state", async () => pr, "failed");
  fail(new Error("late error"));
  await old;
  expect(view.snapshot()).toEqual({ head: pr });
  view.dispose();
});

test("a stale native Fix checks menu item never becomes Address comments or Arm", async () => {
  const { nativeRowToolBindings, createNativeMenuKeys, dispatchNativeRowTool } = await import("./nativeRowTools");
  const keys = createNativeMenuKeys();
  const seen: string[] = [];
  const make = (ids: string[], head = pr) =>
    nativeRowToolBindings(
      [],
      undefined,
      {
        pullRequest: {
          value: pr,
          ops: {
            identity: "same-pr",
            displayed: head,
            merging: { step: "idle" },
            messages: [],
            actions: ids.map((id) => ({
              id: `1:${id}`,
              label: id,
              enabled: true,
              run: () => {
                seen.push(id);
              },
            })),
          },
        },
      },
      undefined,
      keys,
    );
  const first = make(["state", "fixChecks", "addressComments", "arm"]);
  const fix = first[0]!.tool.menu!.find((item) => item.label === "fixChecks")!.id;
  const fresh = make(["state", "addressComments", "arm"], { ...pr, state: "merged" });
  dispatchNativeRowTool({ id: "pullRequest", menuItemId: fix }, fresh);
  expect(seen).toEqual([]);
  expect(fresh[0]!.tool.label).toContain("merged");
});

test("unrelated header updates retain the pending action and authoritative head", async () => {
  const { JSDOM } = await import("jsdom");
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { usePullRequestActions } = await import("./usePullRequestActions");
  const dom = new JSDOM("<div id='root'></div>", { url: "http://localhost/" });
  const globals = globalThis as Record<string, unknown>;
  const previous = new Map(["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"].map((k) => [k, globals[k]]));
  Object.assign(globals, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const root = createRoot(dom.window.document.getElementById("root")!);
  const fresh = { ...pr, headSha: "b".repeat(40), checks: { state: "failing", passed: 0, total: 1 } };
  const seen: string[] = [];
  let signal: AbortSignal | undefined;
  let finish!: (value: HeaderPullRequest) => void;
  let view!: ReturnType<typeof usePullRequestActions>;
  const run: PullRequestAction = async (_, action, current) => {
    seen.push(action);
    if (action === "state") return fresh;
    signal = current;
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  function Harness({ value }: { value: HeaderPullRequest }) {
    view = usePullRequestActions(value, run, "chat-A");
    return null;
  }
  try {
    await act(async () => root.render(createElement(Harness, { value: pr })));
    await act(async () => {
      view.actions.find((action) => action.id.endsWith(":fixChecks"))!.run();
    });
    await act(async () => root.render(createElement(Harness, { value: { ...pr } })));
    expect(seen).toEqual(["state", "fixChecks"]);
    expect(signal?.aborted).toBe(false);
    expect(view.headSha).toBe(fresh.headSha);
    await act(async () => {
      finish(fresh);
    });
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, value] of previous) {
      if (value === undefined) delete globals[key];
      else globals[key] = value;
    }
  }
});
