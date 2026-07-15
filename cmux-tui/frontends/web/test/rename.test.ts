import { describe, expect, it } from "vitest";
import { renameCanCommit, renameReducer } from "../src/lib/rename";

describe("rename flow", () => {
  it("begins, edits, and commits a target", () => {
    const begun = renameReducer(null, {
      type: "begin",
      target: { kind: "workspace", id: 7, value: "old" },
    });
    const edited = renameReducer(begun, { type: "change", value: "new" });
    expect(edited).toEqual({ kind: "workspace", id: 7, value: "new" });
    expect(renameCanCommit(edited)).toBe(true);
    expect(renameReducer(edited, { type: "commit" })).toBeNull();
  });

  it("cancels and rejects whitespace-only names", () => {
    const state = { kind: "screen", id: 9, value: "   " } as const;
    expect(renameCanCommit(state)).toBe(false);
    expect(renameReducer(state, { type: "cancel" })).toBeNull();
  });
});
