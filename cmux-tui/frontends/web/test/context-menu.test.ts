import { describe, expect, it } from "vitest";
import { contextMenuReducer } from "../src/lib/contextMenu";

describe("contextMenuReducer", () => {
  it("opens at the requested viewport point and closes", () => {
    const opened = contextMenuReducer({ open: false }, { type: "open", point: { x: 12, y: 34 } });
    expect(opened).toEqual({ open: true, point: { x: 12, y: 34 } });
    expect(contextMenuReducer(opened, { type: "close" })).toEqual({ open: false });
  });

  it("keeps the same state object for a duplicate open", () => {
    const opened = { open: true, point: { x: 12, y: 34 } } as const;
    expect(contextMenuReducer(opened, { type: "open", point: { x: 12, y: 34 } })).toBe(opened);
  });
});
