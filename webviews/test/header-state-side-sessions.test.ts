// Debug Settings' Side sessions (/btw) arrives in the App's header state. The page's own partial
// updates (Hide tabs answers `{ sideTabs }` alone) must keep it, or `/btw` falls back to a chat prompt.
import { expect, test } from "bun:test";

test("the shipped default stays on until the App explicitly turns it off", async () => {
  const { headerState, setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  expect(headerState().sideSessions).toBe(true);
  setHeaderState({ sideTabs: false, sideSessions: true, version: 1 });
  expect(headerState().sideSessions).toBe(true);
  setHeaderState({ sideTabs: true });
  expect(headerState().sideSessions).toBe(true);
  setHeaderState({ sideSessions: "yes", version: 2 });
  expect(headerState().sideSessions).toBe(true);
  setHeaderState({ sideSessions: false, version: 3 });
  expect(headerState().sideSessions).toBe(false);
});
