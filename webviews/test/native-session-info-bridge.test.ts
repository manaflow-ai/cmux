import { afterEach, expect, test } from "bun:test";
import {
  nativeSessionInfoDrawn,
  runNativeSessionInfoAction,
  setNativeSessionInfoActions,
  setNativeSessionInfoHost,
} from "../src/agent-session/acpmux/session-info/native/host";
import { NativeInfoActions, NATIVE_ACTION_ID_MAX } from "../src/agent-session/acpmux/session-info/native/model";

afterEach(() => {
  setNativeSessionInfoActions(undefined);
  setNativeSessionInfoHost(false);
});

test("only an explicit native capability enables the native path", () => {
  for (const value of [undefined, null, "true", 1, {}, false]) {
    setNativeSessionInfoHost(value);
    expect(nativeSessionInfoDrawn()).toBe(false);
  }
  setNativeSessionInfoHost(true);
  expect(nativeSessionInfoDrawn()).toBe(true);
  setNativeSessionInfoHost(false);
  expect(nativeSessionInfoDrawn()).toBe(false);
});

test("a native row runs its page handler, and replaced models retire old handlers", async () => {
  let opened = 0;
  const first = new NativeInfoActions();
  const key = first.add("source:/project/file.ts", () => opened++);
  setNativeSessionInfoActions(first);
  runNativeSessionInfoAction(key);
  await Promise.resolve();
  expect(opened).toBe(1);
  setNativeSessionInfoActions(new NativeInfoActions());
  runNativeSessionInfoAction(key);
  await Promise.resolve();
  expect(opened).toBe(1);
});

test("long Unicode action ids stay bounded and route to the right original handler", async () => {
  const actions = new NativeInfoActions();
  const opened: string[] = [];
  const prefix = "source:" + "😀".repeat(500);
  const a = actions.add(prefix + "a", () => opened.push("a"));
  const b = actions.add(prefix + "b", () => opened.push("b"));
  expect(a.length).toBeLessThanOrEqual(NATIVE_ACTION_ID_MAX);
  expect(a).not.toBe(b);
  expect(a).not.toContain("\uFFFD");
  setNativeSessionInfoActions(actions);
  runNativeSessionInfoAction(b);
  runNativeSessionInfoAction(a);
  await Promise.resolve();
  expect(opened).toEqual(["b", "a"]);
});

test("malformed events are ignored and only the current model can dispatch actions", () => {
  const received: string[] = [];
  setNativeSessionInfoActions(new NativeInfoActions(), (id) => {
    received.push(id);
    return true;
  });
  for (const value of [null, 12, {}, "", "x".repeat(NATIVE_ACTION_ID_MAX + 1)]) runNativeSessionInfoAction(value);
  expect(received).toEqual([]);
  runNativeSessionInfoAction("close");
  expect(received).toEqual(["close"]);
  setNativeSessionInfoActions(undefined);
  runNativeSessionInfoAction("close");
  expect(received).toEqual(["close"]);
});

test("a native row's page rectangle reaches its popover handler", async () => {
  const actions = new NativeInfoActions();
  let anchor: unknown;
  const id = actions.add("environment.addRepository", (rect) => {
    anchor = rect;
  });
  setNativeSessionInfoActions(actions);
  const rect = { left: 640, top: 100, right: 920, bottom: 126 };
  runNativeSessionInfoAction({ id, rect });
  await Promise.resolve();
  expect(anchor).toEqual(rect);
  anchor = undefined;
  runNativeSessionInfoAction({ id, rect: { ...rect, right: NaN } });
  runNativeSessionInfoAction({ id, rect: { ...rect, bottom: 20 } });
  await Promise.resolve();
  expect(anchor).toBeUndefined();
});
