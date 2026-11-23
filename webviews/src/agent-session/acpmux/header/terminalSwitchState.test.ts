import { afterEach, expect, test } from "bun:test";
import { headerState, resetHeaderStateForTests, setHeaderState } from "./headerState";

afterEach(() => resetHeaderStateForTests());

// The App's `pane.tabState` reply says whether a terminal runs the chat's session (`terminalSwitch`); a
// `headerState` push leaves it out and keeps the last reply's answer.
test("terminalSwitch follows the tab state reply and survives a push without it", () => {
  expect(headerState().terminalSwitch).toBe(false);
  setHeaderState({ terminalSwitch: true, moves: [], version: 1 });
  expect(headerState().terminalSwitch).toBe(true);
  setHeaderState({ pinned: true, version: 2 });
  expect(headerState().terminalSwitch).toBe(true);
  setHeaderState({ terminalSwitch: false, moves: [], version: 3 });
  expect(headerState().terminalSwitch).toBe(false);
});
