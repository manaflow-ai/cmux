import { describe, expect, test } from "bun:test";
import { stopTurnFromAction } from "./stopTurnAction";

describe("Stop Agent Turn", () => {
  test("cancels the current working turn", () => {
    const stopped: string[] = [];
    expect(stopTurnFromAction(true, () => stopped.push("cancel"))).toBe(true);
    expect(stopped).toEqual(["cancel"]);
  });

  test("ignores an idle or stale command", () => {
    const stopped: string[] = [];
    expect(stopTurnFromAction(false, () => stopped.push("cancel"))).toBe(false);
    expect(stopped).toEqual([]);
  });
});
