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
});
