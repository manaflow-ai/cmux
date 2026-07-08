import { describe, expect, test } from "bun:test";
import { createDiffViewerLabelResolver } from "../src/labels";

describe("createDiffViewerLabelResolver", () => {
  test("uses localized payload labels first", () => {
    const label = createDiffViewerLabelResolver({ hideFiles: "Hide changed files" });

    expect(label("hideFiles")).toBe("Hide changed files");
  });

  test("falls back to shipped default labels instead of raw keys", () => {
    const label = createDiffViewerLabelResolver(undefined);

    expect(label("hideFiles")).toBe("Hide files");
  });

  test("fails fast for missing payload labels in development mode", () => {
    const label = createDiffViewerLabelResolver(undefined, { assertMissing: true });

    expect(() => label("hideFiles")).toThrow("Missing cmux diff viewer label: hideFiles");
  });

  test("deduplicates missing payload label assertions", () => {
    const label = createDiffViewerLabelResolver(undefined, { assertMissing: true });

    expect(() => label("hideFiles")).toThrow("Missing cmux diff viewer label: hideFiles");
    expect(label("hideFiles")).toBe("Hide files");
  });

  test("falls back to defaults for empty payload labels", () => {
    const label = createDiffViewerLabelResolver({ hideFiles: "  " });

    expect(label("hideFiles")).toBe("Hide files");
  });
});
