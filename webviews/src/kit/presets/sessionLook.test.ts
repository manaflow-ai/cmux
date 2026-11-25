// The theme-file reader of the kit's session list: minimal-sessions.json's keys give the minimal
// look, unknown keys and wrong types are ignored, and the base look stays unchanged.
import { expect, test } from "bun:test";
import { DEFAULT_SESSION_LOOK, MINIMAL_SESSIONS_LOOK, sessionLook } from "./sessionLook";

test("minimal-sessions.json's keys over the default look give the minimal look", () => {
  const themeFile = {
    name: "Minimal sessions",
    "sidebar.density": "compact",
    "sidebar.textSize": "default",
    "sidebar.workspaceRow.statusPlacement": "leading",
    "sidebar.detailedStatusIcons": true,
    "sidebar.workspaceRow.icon": false,
    "sidebar.workspaceRow.directory": false,
    "sidebar.workspaceRow.branch": false,
    "sidebar.workspaceRow.tabCount": false,
    "sidebar.workspaceRow.lastActivity": false,
    "sidebar.showColors": false,
  };
  expect(sessionLook(themeFile)).toEqual(MINIMAL_SESSIONS_LOOK);
});

test("wrong types and unknown values are ignored", () => {
  const look = sessionLook({
    "sidebar.density": "roomy",
    "sidebar.workspaceRow.statusPlacement": 1,
    "sidebar.workspaceRow.icon": "no",
  });
  expect(look).toEqual(DEFAULT_SESSION_LOOK);
});

test("the base look is not changed", () => {
  const before = { ...MINIMAL_SESSIONS_LOOK };
  sessionLook({ "sidebar.density": "comfortable" }, MINIMAL_SESSIONS_LOOK);
  expect(MINIMAL_SESSIONS_LOOK).toEqual(before);
});
