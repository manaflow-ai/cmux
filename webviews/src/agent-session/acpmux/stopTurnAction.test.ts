import { describe, expect, test } from "bun:test";
import { stopTurnFromAction } from "./stopTurnAction";

describe("Stop Agent Turn", () => {
  test("cancels the current working turn", () => {
    const stopped: string[] = [];
    expect(
      stopTurnFromAction({ sessionId: "chat-a", isWorking: true }, "chat-a", "chat-a", () => stopped.push("cancel")),
    ).toBe(true);
    expect(stopped).toEqual(["cancel"]);
  });

  test("ignores an idle or stale command", () => {
    const stopped: string[] = [];
    expect(
      stopTurnFromAction({ sessionId: "chat-b", isWorking: true }, "chat-a", "chat-a", () => stopped.push("cancel")),
    ).toBe(false);
    expect(
      stopTurnFromAction({ sessionId: "chat-a", isWorking: true }, "chat-a", "chat-b", () => stopped.push("cancel")),
    ).toBe(false);
    expect(
      stopTurnFromAction({ sessionId: "chat-a", isWorking: false }, "chat-a", "chat-a", () => stopped.push("cancel")),
    ).toBe(false);
    expect(stopped).toEqual([]);
  });
});
