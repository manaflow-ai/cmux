import { afterEach, expect, jest, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { importWithDom } from "../../../test/support/importWithDom";
const { AUTO_RETRY_MAX_MS, AutoRetryLoop, useAutoRetry } = await importWithDom(() => import("./autoRetry"));
const { LASTING_MS } = await importWithDom(() => import("../../ui/lasting"));

// `random` 1 makes jitteredDelay return the full step: 1 s, 2 s, 4 s, ...
const full = () => 1;

afterEach(() => {
  jest.useRealTimers();
});

test("asks again with a doubling, jittered backoff while the failure lasts, and stops on success", () => {
  jest.useFakeTimers();
  let asks = 0;
  const loop = new AutoRetryLoop(() => asks++, { random: full, visible: () => true });
  loop.fail();
  jest.advanceTimersByTime(999);
  expect(asks).toBe(0);
  jest.advanceTimersByTime(1);
  expect(asks).toBe(1);
  // No new failure reported: the loop still asks again, after the doubled step.
  jest.advanceTimersByTime(1_999);
  expect(asks).toBe(1);
  jest.advanceTimersByTime(1);
  expect(asks).toBe(2);
  loop.succeed();
  jest.advanceTimersByTime(60_000);
  expect(asks).toBe(2);
  // A new stretch starts the backoff over.
  loop.fail();
  jest.advanceTimersByTime(1_000);
  expect(asks).toBe(3);
  loop.dispose();
});

test("the wait is jittered to 50-100% of the step and capped", () => {
  jest.useFakeTimers();
  let asks = 0;
  const loop = new AutoRetryLoop(() => asks++, { random: () => 0, visible: () => true });
  loop.fail();
  jest.advanceTimersByTime(500);
  expect(asks).toBe(1);
  for (let i = 0; i < 20; i++) jest.advanceTimersByTime(AUTO_RETRY_MAX_MS / 2);
  const before = asks;
  jest.advanceTimersByTime(AUTO_RETRY_MAX_MS / 2);
  expect(asks).toBe(before + 1);
  loop.dispose();
});

test("a repeated failure report while an ask is armed does not reset or double the wait", () => {
  jest.useFakeTimers();
  let asks = 0;
  const loop = new AutoRetryLoop(() => asks++, { random: full, visible: () => true });
  loop.fail();
  jest.advanceTimersByTime(500);
  loop.fail();
  jest.advanceTimersByTime(500);
  expect(asks).toBe(1);
  loop.dispose();
});

test("pause holds the asks while an attempt is in flight", () => {
  jest.useFakeTimers();
  let asks = 0;
  const loop = new AutoRetryLoop(() => asks++, { random: full, visible: () => true });
  loop.fail();
  loop.pause();
  jest.advanceTimersByTime(10_000);
  expect(asks).toBe(0);
  loop.fail();
  jest.advanceTimersByTime(1_000);
  expect(asks).toBe(1);
  loop.dispose();
});

test("a hidden view asks nothing and asks once at once when it shows again", () => {
  jest.useFakeTimers();
  let asks = 0;
  let visible = true;
  const loop = new AutoRetryLoop(() => asks++, { random: full, visible: () => visible });
  loop.fail();
  visible = false;
  loop.wake();
  jest.advanceTimersByTime(120_000);
  expect(asks).toBe(0);
  visible = true;
  loop.wake();
  expect(asks).toBe(1);
  // The component's own shown state gates it too.
  loop.setShown(false);
  jest.advanceTimersByTime(120_000);
  expect(asks).toBe(1);
  loop.setShown(true);
  expect(asks).toBe(2);
  loop.dispose();
  jest.advanceTimersByTime(120_000);
  expect(asks).toBe(2);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
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
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

test("the hook retries a failing read on its own and says 'still trying' only past the deadline", async () => {
  jest.useFakeTimers();
  const container = installDom();
  let asks = 0;
  let heal: (() => void) | undefined;
  function Probe() {
    const [error, setError] = useState<Error | undefined>(new Error("refused"));
    heal = () => setError(undefined);
    const { stillTrying } = useAutoRetry(
      error,
      () => {
        asks++;
        setError(new Error("refused again"));
      },
      { random: full },
    );
    return <span>{error ? (stillTrying ? "still trying" : "quiet") : "ok"}</span>;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Probe />);
  });
  expect(container.textContent).toBe("quiet");
  await wait(1_000);
  expect(asks).toBe(1);
  await wait(LASTING_MS - 1_001);
  expect(container.textContent).toBe("quiet");
  await wait(1);
  expect(container.textContent).toBe("still trying");
  const sofar = asks;
  expect(sofar).toBeGreaterThan(3);
  await act(async () => heal!());
  expect(container.textContent).toBe("ok");
  await wait(120_000);
  expect(asks).toBe(sofar);
});

test("the hook keeps the stretch through an attempt in flight and asks once when the page shows again", async () => {
  jest.useFakeTimers();
  const container = installDom();
  let asks = 0;
  let setBusy: ((busy: boolean) => void) | undefined;
  function Probe() {
    const [busy, set] = useState(false);
    setBusy = set;
    const { stillTrying } = useAutoRetry(busy ? undefined : "failed", () => asks++, { busy, random: full });
    return <span>{stillTrying ? "still trying" : "quiet"}</span>;
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<Probe />);
  });
  await act(async () => setBusy!(true));
  await wait(LASTING_MS);
  // In flight the whole time: no ask, but the failure stretch went on.
  expect(asks).toBe(0);
  expect(container.textContent).toBe("still trying");
  await act(async () => setBusy!(false));
  Object.defineProperty(dom!.window.document, "visibilityState", { value: "hidden", configurable: true });
  await act(async () => void dom!.window.document.dispatchEvent(new dom!.window.Event("visibilitychange")));
  await wait(120_000);
  expect(asks).toBe(0);
  Object.defineProperty(dom!.window.document, "visibilityState", { value: "visible", configurable: true });
  await act(async () => void dom!.window.document.dispatchEvent(new dom!.window.Event("visibilitychange")));
  expect(asks).toBe(1);
});
