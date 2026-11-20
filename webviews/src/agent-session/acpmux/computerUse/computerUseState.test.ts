// What the app says of Computer Use (`chat.computerUse.state`), and which answers hold a send that
// names @computer-use (CMUX-682).
import { expect, test } from "bun:test";
import { computerUseGate, holdsForComputerUse, readComputerUseState } from "./computerUseState";

test("only the app's four answers are read; anything else is unknown", () => {
  expect(readComputerUseState({ state: "ready" })).toBe("ready");
  expect(readComputerUseState({ state: "starting" })).toBe("starting");
  expect(readComputerUseState({ state: "needs_setup" })).toBe("needs_setup");
  expect(readComputerUseState({ state: "disabled" })).toBe("disabled");
  expect(readComputerUseState({ state: "off" })).toBeUndefined();
  expect(readComputerUseState("ready")).toBeUndefined();
  expect(readComputerUseState(null)).toBeUndefined();
});

test("a send goes only when Computer Use is ready; an app that cannot answer sends", () => {
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
  // An app too old to answer: nothing to check, so it sends.
  expect(computerUseGate(text, undefined)).toBe("free");
  // No @computer-use (browser use, code, a file named after it): never held.
  for (const other of ["check it with @browser-use", "run `@computer-use`", "read @computer-use.md"])
    expect(computerUseGate(other, "needs_setup")).toBe("free");
  // Codex's $ mark counts too.
  expect(computerUseGate("open it with $computer-use", "needs_setup")).toBe("setup");
});
