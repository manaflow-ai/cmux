import { describe, expect, test } from "bun:test";

const entry = (await import("../src/agent-session/acpmux/ComposerContext.gallery")).default;

describe("composer scope row gallery", () => {
  test("keeps the unified composer context states and menu plays covered", () => {
    expect(entry.id).toBe("agent-pane.composer-context");
    expect(entry.covers).toContain("agent-session/acpmux/ComposerContext.tsx#ComposerContext");
    expect(Object.keys(entry.variants)).toEqual(["closed", "folder-menu", "computer-menu", "started-branch"]);
    expect(entry.variants["folder-menu"]?.play).toBeTypeOf("function");
    expect(entry.variants["computer-menu"]?.play).toBeTypeOf("function");
    expect(entry.variants["started-branch"]?.props).toMatchObject({ started: true });
  });
});
