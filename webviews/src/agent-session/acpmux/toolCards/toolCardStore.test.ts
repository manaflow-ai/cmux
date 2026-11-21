import { describe, expect, test } from "bun:test";
import { currentToolCards, setToolCards } from "./toolCardStore";

describe("toolCardStore", () => {
  test("keeps a done card: a started Cloud session's link to its chat", () => {
    setToolCards([
      {
        id: "cloud-start-session-tab_1",
        state: "done",
        text: "claude runs on Cloud machine dev.",
        actions: [
          { id: "open", title: "Open Chat" },
          { id: "dismiss", title: "Dismiss" },
        ],
      },
    ]);
    expect(currentToolCards()).toEqual([
      {
        id: "cloud-start-session-tab_1",
        state: "done",
        text: "claude runs on Cloud machine dev.",
        actions: [
          { id: "open", title: "Open Chat" },
          { id: "dismiss", title: "Dismiss" },
        ],
      },
    ]);
  });

  test("drops a card whose state it does not know", () => {
    setToolCards([{ id: "x", state: "finished", text: "t", actions: [] }]);
    expect(currentToolCards()).toEqual([]);
  });

  test("keeps an action's checkmark state, and only a boolean one", () => {
    setToolCards([
      {
        id: "cloud-start-session-tab_1",
        state: "working",
        text: "Starting claude on a Cloud machine.",
        actions: [
          { id: "askFirst", title: "Ask me first", check: false },
          { id: "dismiss", title: "Dismiss", check: "yes" },
        ],
      },
    ]);
    expect(currentToolCards()[0]?.actions).toEqual([
      { id: "askFirst", title: "Ask me first", check: false },
      { id: "dismiss", title: "Dismiss" },
    ]);
  });
});
