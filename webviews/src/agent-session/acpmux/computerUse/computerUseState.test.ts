// Computer Use on this Mac, as the app pushes it (`computerUseState` event), and what a send that
// names @computer-use does with it (CMUX-682): decided at once on the latest push, never on an answer
// still on its way.
import { expect, test } from "bun:test";
import {
  computerUseGate,
  computerUseState,
  holdsForComputerUse,
  readComputerUseState,
  setComputerUseState,
} from "./computerUseState";

test("only the app's four answers are read; anything else is unknown", () => {
  expect(readComputerUseState("ready")).toBe("ready");
  expect(readComputerUseState("starting")).toBe("starting");
  expect(readComputerUseState("needs_setup")).toBe("needs_setup");
  expect(readComputerUseState("disabled")).toBe("disabled");
  expect(readComputerUseState("off")).toBeUndefined();
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
  expect(holdsForComputerUse("starting")).toBe(true);
  expect(holdsForComputerUse("ready")).toBe(false);
  expect(holdsForComputerUse(undefined)).toBe(false);
});

test("a send naming @computer-use goes only when ready; otherwise setup opens, or the notice says why", () => {
  const text = "open the settings app with @computer-use";
  expect(computerUseGate(text, "ready")).toBe("free");
  expect(computerUseGate(text, "needs_setup")).toBe("setup");
  expect(computerUseGate(text, "starting")).toBe("setup");
  expect(computerUseGate(text, "disabled")).toBe("notice");
  expect(computerUseGate(text, undefined)).toBe("free");
  for (const other of ["check it with @browser-use", "run `@computer-use`", "read @computer-use.md"])
    expect(computerUseGate(other, "needs_setup")).toBe("free");
  expect(computerUseGate("open it with $computer-use", "needs_setup")).toBe("setup");
});
