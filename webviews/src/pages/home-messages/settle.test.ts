import { describe, expect, it } from "bun:test";
import { settle } from "./settle";

describe("settle before the page closes", () => {
  it("saves first, then answers once nothing is held alone", async () => {
    const order: string[] = [];
    let left = 3;
    const answer = await settle(
      () => order.push("flush"),
      () => (left-- > 0 ? "home.draft" : null),
      {},
      async () => void order.push("wait"),
    );
    expect(answer).toEqual({ held: null });
    expect(order).toEqual(["flush", "wait", "wait", "wait"]);
  });

  it("answers with what is still held at its bound", async () => {
    let waits = 0;
    const answer = await settle(
      () => {},
      () => "home.uploading",
      { within: 100 },
      async () => void waits++,
    );
    expect(answer).toEqual({ held: "home.uploading" });
    expect(waits).toBe(2);
  });
});
