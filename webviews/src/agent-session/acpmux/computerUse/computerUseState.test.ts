// Computer Use on this Mac, as the app pushes it (`computerUseState` event), and what a send that
// names @computer-use does with it (CMUX-682): decided at once on the latest push, never on an answer
// still on its way.
import { expect, test } from "bun:test";
import {
  holdOpensSetup,
  computerUseGate,
  computerUseHold,
  computerUseHoldText,
  computerUseState,
  holdsForComputerUse,
  readComputerUseState,
  setComputerUseState,
} from "./computerUseState";

test("only the app's five answers are read; anything else is unknown", () => {
  expect(readComputerUseState("ready")).toBe("ready");
  expect(readComputerUseState("starting")).toBe("starting");
  expect(readComputerUseState("needs_setup")).toBe("needs_setup");
  expect(readComputerUseState("unavailable")).toBe("unavailable");
  expect(readComputerUseState("disabled")).toBe("disabled");
  expect(readComputerUseState("off")).toBeUndefined();
  // A newer app's state this page does not know sends, as an older app's silence does.
  expect(readComputerUseState("some_future_state")).toBeUndefined();
  expect(readComputerUseState({ state: "ready" })).toBeUndefined();
  expect(readComputerUseState(null)).toBeUndefined();
});

test("the latest push is the state a send reads", () => {
  setComputerUseState("needs_setup");
  expect(computerUseState()).toBe("needs_setup");
  setComputerUseState("ready");
  expect(computerUseState()).toBe("ready");
  setComputerUseState(null);
  expect(computerUseState()).toBeUndefined();
});

test("a send waits only while not ready; an app that cannot answer sends", () => {
  expect(holdsForComputerUse("needs_setup")).toBe(true);
  expect(holdsForComputerUse("disabled")).toBe(true);
  expect(holdsForComputerUse("unavailable")).toBe(true);
  expect(holdsForComputerUse("starting")).toBe(true);
  expect(holdsForComputerUse("ready")).toBe(false);
  expect(holdsForComputerUse(undefined)).toBe(false);
});

test("a send naming @computer-use goes only when ready; otherwise setup opens, or the notice says why", () => {
  const text = "open the settings app with @computer-use";
  expect(computerUseGate(text, "ready")).toBe("free");
  expect(computerUseGate(text, "needs_setup")).toBe("setup");
  expect(computerUseGate(text, "starting")).toBe("setup");
  expect(computerUseGate(text, "disabled")).toBe("disabled");
  expect(computerUseGate(text, "unavailable")).toBe("unavailable");
  expect(computerUseGate(text, undefined)).toBe("free");
  expect(computerUseGate(text, readComputerUseState("some_future_state"))).toBe("free");
  for (const other of ["check it with @browser-use", "run `@computer-use`", "read @computer-use.md"])
    expect(computerUseGate(other, "needs_setup")).toBe("free");
  expect(computerUseGate("open it with $computer-use", "needs_setup")).toBe("setup");
});

test("a chat off this Mac holds every @computer-use send, whatever this Mac's state (#48541)", () => {
  const text = "open the settings app with @computer-use";
  for (const state of ["ready", "starting", "needs_setup", "unavailable", "disabled", undefined] as const) {
    expect(computerUseGate(text, state, "cloud")).toBe("cloud");
    expect(computerUseGate(text, state, "machine")).toBe("machine");
  }
  // Ready on this Mac, it goes; a send that names no @computer-use goes anywhere.
  expect(computerUseGate(text, "ready", "here")).toBe("free");
  expect(computerUseGate("check it with @browser-use", "ready", "cloud")).toBe("free");
  expect(computerUseGate("plain words", "needs_setup", "machine")).toBe("free");
});

test("the notice says why with setup only where setup can fix it", () => {
  expect(computerUseHold("needs_setup")).toBe("setup");
  expect(computerUseHold("ready")).toBeUndefined();
  expect(computerUseHold("ready", "cloud")).toBe("cloud");
  expect(computerUseHoldText("setup")).toEqual({ title: "computerUseSetup.title", detail: "computerUseSetup.detail" });
  expect(computerUseHoldText("disabled")).toEqual({ title: "computerUseSetup.disabledTitle" });
  expect(computerUseHoldText("unavailable")).toEqual({
    title: "computerUseSetup.unavailableTitle",
    detail: "computerUseSetup.unavailableDetail",
  });
  expect(computerUseHoldText("cloud")).toEqual({
    title: "computerUseSetup.remoteTitle",
    detail: "computerUseSetup.cloudDetail",
  });
  expect(computerUseHoldText("machine")).toEqual({
    title: "computerUseSetup.remoteTitle",
    detail: "computerUseSetup.machineDetail",
  });
});

test("the send's own key press opens the setup page when setup or a build that can run it would help", () => {
  expect(holdOpensSetup("setup")).toBe(true);
  expect(holdOpensSetup("unavailable")).toBe(true);
  for (const hold of ["disabled", "cloud", "machine"] as const) expect(holdOpensSetup(hold)).toBe(false);
});
