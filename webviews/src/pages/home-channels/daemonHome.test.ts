import { describe, expect, test } from "bun:test";
import { conversation } from "./daemonHome";

describe("a daemon conversation", () => {
  test("carries the others' read cursors for my Read receipts, never mine or an empty one", () => {
    const shown = conversation(
      {
        id: "c1",
        participants: [
          { id: "me", kind: "human", display_name: "Me" },
          { id: "ana", kind: "human", display_name: "Ana" },
          { id: "sam", kind: "human", display_name: "Sam" },
        ],
        last_seq: 4,
        read_cursors: { me: 4, ana: 3, sam: 0 },
      },
      "me",
    );
    expect(shown.readCursors).toEqual({ ana: { seq: 3 } });
    expect(shown.unread).toBe(0);
  });

  test("has no cursors when no one else read", () => {
    expect(conversation({ id: "c2", participants: [], read_cursors: { me: 2 } }, "me").readCursors).toBeUndefined();
  });
});
