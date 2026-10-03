import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useTurnCheckpoints } = await import("./useTurnCheckpoints");
type Hook = ReturnType<typeof useTurnCheckpoints>;
type Read = Parameters<typeof useTurnCheckpoints>[0];

async function mount(read: Read, sessionId: string) {
  const hook: { current?: Hook } = {};
  function Probe(props: { read: Read; sessionId: string }) {
    hook.current = useTurnCheckpoints(props.read, props.sessionId);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (next: string) => act(async () => root.render(createElement(Probe, { read, sessionId: next })));
  await render(sessionId);
  return { hook, render, unmount: () => act(async () => root.unmount()) };
}

const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("without a host read every turn is unsupported", async () => {
  const { hook, unmount } = await mount(undefined, "s1");
  expect(hook.current!.get("user-1")).toEqual({ state: "unsupported" });
  await unmount();
});

test("a turn is read once, a failed read is asked again, and an unasked turn has no answer", async () => {
  const asked: string[] = [];
  let fail = true;
  const read: Read = async ({ rowId }) => {
    asked.push(rowId);
    if (fail) throw new Error("host down");
    return { checkpoint_id: "cp", complete: true, diff: { files: [] } };
  };
  const { hook, unmount } = await mount(read, "s1");
  expect(hook.current!.get("user-1")).toBeUndefined();
  await act(async () => hook.current!.request("user-1"));
  await flush();
  expect(hook.current!.get("user-1")).toEqual({ state: "error", message: "host down" });
  fail = false;
  await act(async () => hook.current!.request("user-1"));
  await flush();
  expect(hook.current!.get("user-1")?.state).toBe("loaded");
  await act(async () => hook.current!.request("user-1"));
  await flush();
  expect(asked).toEqual(["user-1", "user-1"]);
  await unmount();
});

test("an answer that arrives after the session changed is dropped", async () => {
  let answer: (value: unknown) => void = () => {};
  const read: Read = () => new Promise((resolve) => (answer = resolve));
  const { hook, render, unmount } = await mount(read, "s1");
  await act(async () => hook.current!.request("user-1"));
  expect(hook.current!.get("user-1")).toEqual({ state: "loading" });
  await render("s2");
  answer(null);
  await flush();
  expect(hook.current!.get("user-1")).toBeUndefined();
  await unmount();
});
