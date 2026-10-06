import { describe, expect, test } from "bun:test";
import {
  createDiffViewerLabelResolver,
  DEFAULT_DIFF_VIEWER_LABELS,
  diffViewerLanguage,
  JAPANESE_DIFF_VIEWER_LABELS,
  type DiffViewerLabelKey,
} from "../src/labels";

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

describe("Japanese labels", () => {
  test("the Japanese table covers every key and keeps placeholders", () => {
    for (const key of Object.keys(DEFAULT_DIFF_VIEWER_LABELS) as DiffViewerLabelKey[]) {
      const english = DEFAULT_DIFF_VIEWER_LABELS[key];
      const japanese = JAPANESE_DIFF_VIEWER_LABELS[key];
      expect(japanese.trim()).not.toBe("");
      expect(japanese.match(/\{[a-z]+\}/g)?.sort() ?? []).toEqual(english.match(/\{[a-z]+\}/g)?.sort() ?? []);
    }
  });

  test("the app language picks the table, and host labels still win", () => {
    expect(diffViewerLanguage(["ja-JP", "en-US"])).toBe("ja");
    expect(diffViewerLanguage(["en-US", "ja-JP"])).toBe("en");
    expect(diffViewerLanguage(["fr-FR"])).toBe("en");
    const japanese = createDiffViewerLabelResolver(undefined, { language: "ja" });
    expect(japanese("loadFullFiles")).toBe("ファイル全体を読み込む");
    expect(japanese("sourceUncommitted")).toBe("未コミット");
    const hosted = createDiffViewerLabelResolver({ hideFiles: "Host text" }, { language: "ja" });
    expect(hosted("hideFiles")).toBe("Host text");
    expect(createDiffViewerLabelResolver(undefined, { language: "en" })("loadFullFiles")).toBe("Load full files");
  });
});
