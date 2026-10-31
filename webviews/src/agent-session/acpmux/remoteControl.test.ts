import { beforeEach, expect, test } from "bun:test";
import { readRemoteControl, remoteControl, setRemoteControl, toggleRemoteControl } from "./remoteControl";

beforeEach(() => setRemoteControl(null));

test("the App's push sets the switch, and null or a bad value means no row", () => {
  setRemoteControl({ on: true });
  expect(remoteControl()).toEqual({ on: true });
  setRemoteControl({ on: false });
  expect(remoteControl()).toEqual({ on: false });
  setRemoteControl(null);
  expect(remoteControl()).toBeNull();
  for (const bad of [{}, { on: "true" }, true, "on", 1]) expect(readRemoteControl(bad)).toBeNull();
});

test("a click writes through pane.setRemoteControl and shows the new value at once", async () => {
  setRemoteControl({ on: false });
  const calls: [string, Record<string, unknown>][] = [];
  const done = toggleRemoteControl(true, async (method, params) => {
    calls.push([method, params]);
    expect(remoteControl()).toEqual({ on: true });
  });
  await done;
  expect(calls).toEqual([["pane.setRemoteControl", { on: true }]]);
  expect(remoteControl()).toEqual({ on: true });
});

test("a refused write puts the switch back", async () => {
  setRemoteControl({ on: false });
  await toggleRemoteControl(true, () => Promise.reject(new Error("gesture_required")));
  expect(remoteControl()).toEqual({ on: false });
});

test("no switch means a click calls nothing (never a dead write)", async () => {
  let called = false;
  await toggleRemoteControl(true, async () => {
    called = true;
  });
  expect(called).toBe(false);
  expect(remoteControl()).toBeNull();
});

test("overlapping clicks that both fail end on the App's value, not an earlier click's", async () => {
  setRemoteControl({ on: false });
  let rejectFirst: (error: Error) => void = () => undefined;
  const first = toggleRemoteControl(true, () => new Promise((_, reject) => (rejectFirst = reject)));
  const second = toggleRemoteControl(false, () => Promise.reject(new Error("refused")));
  await second;
  rejectFirst(new Error("refused"));
  await first;
  expect(remoteControl()).toEqual({ on: false });
});
