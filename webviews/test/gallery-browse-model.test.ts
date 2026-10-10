import { describe, expect, test } from "bun:test";
import { nextBrowseVariant, resolveBrowseVariant } from "../src/gallery/shell/browseModel";

describe("gallery browse variants", () => {
  test("keeps the current variant when the registry still contains it", () => {
    expect(resolveBrowseVariant("streaming", "idle", ["idle", "streaming"])).toBe("streaming");
  });

  test("falls back to the recommended variant when a selected state disappears", () => {
    expect(resolveBrowseVariant("removed", "idle", ["idle", "done"])).toBe("idle");
  });

  test("falls back to the first real state when both selections disappear", () => {
    expect(resolveBrowseVariant("removed", "also-removed", ["done", "error"])).toBe("done");
    expect(resolveBrowseVariant("removed", undefined, [])).toBeUndefined();
  });

  test("cycles only through states that exist in the refreshed registry", () => {
    expect(nextBrowseVariant("removed", ["idle", "done"])).toBe("idle");
    expect(nextBrowseVariant("idle", ["idle", "done"])).toBe("done");
  });
});
