import { beforeAll, describe, expect, test } from "bun:test";
import {
  createDiffViewerLabelResolver,
  DEFAULT_DIFF_VIEWER_LABELS,
  diffViewerLanguage,
  diffViewerLabelsFor,
  loadDiffViewerLabels,
  type DiffViewerLabelKey,
} from "../src/labels";

beforeAll(async () => {
  await loadDiffViewerLabels("ja");
  await loadDiffViewerLabels("de");
});

describe("createDiffViewerLabelResolver", () => {
  test("uses localized payload labels first", () => {
    const label = createDiffViewerLabelResolver({ hideFiles: "Hide changed files" });

    expect(label("hideFiles")).toBe("Hide changed files");
  });

  test("falls back to shipped default labels instead of raw keys", () => {
    const label = createDiffViewerLabelResolver(undefined);

    expect(label("hideFiles")).toBe("Hide files");
  });

  test("development mode accepts catalog labels without a payload", () => {
    const label = createDiffViewerLabelResolver(undefined, { assertMissing: true });
    expect(label("hideFiles")).toBe("Hide files");
  });

  test("asserts only labels missing from the catalog, once per key", () => {
    const label = createDiffViewerLabelResolver(undefined, { assertMissing: true });
    const missing = "missing" as DiffViewerLabelKey;
    expect(() => label(missing)).toThrow("Missing cmux diff viewer label: missing");
    expect(label(missing)).toBe("diffViewer.missing");
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
      const japanese = diffViewerLabelsFor("ja")[key];
      expect(japanese.trim()).not.toBe("");
      expect(japanese.match(/\{[a-z]+\}/g)?.sort() ?? []).toEqual(english.match(/\{[a-z]+\}/g)?.sort() ?? []);
    }
  });

  test("the app language picks the table, and host labels still win", () => {
    expect(diffViewerLanguage(["ja-JP", "en-US"])).toBe("ja");
    expect(diffViewerLanguage(["en-US", "ja-JP"])).toBe("en");
    expect(diffViewerLanguage(["fr-FR"])).toBe("fr");
    const japanese = createDiffViewerLabelResolver(undefined, { language: "ja" });
    expect(japanese("loadFullFiles")).toBe("ファイル全体を読み込む");
    expect(japanese("sourceUncommitted")).toBe("未コミット");
    const hosted = createDiffViewerLabelResolver({ hideFiles: "Host text" }, { language: "ja" });
    expect(hosted("hideFiles")).toBe("Host text");
    expect(createDiffViewerLabelResolver(undefined, { language: "en" })("loadFullFiles")).toBe("Load full files");
  });
});

// Host-free labels must use the same locale catalog as the other webview pages.
test("Japanese and German labels render without host labels", async () => {
  const { renderToStaticMarkup } = await import("react-dom/server");
  const { createElement } = await import("react");
  const { ViewMenuButton } = await import("../src/DiffToolbar");
  for (const [tag, expected] of [
    ["ja-JP", "ファイルを隠す"],
    ["de-DE", "Dateien ausblenden"],
  ]) {
    const label = createDiffViewerLabelResolver(undefined, { language: diffViewerLanguage([tag!]) });
    const html = renderToStaticMarkup(
      createElement(ViewMenuButton, { icon: "files", label: label("hideFiles"), onClick: () => {} }),
    );
    expect(html).toContain(expected!);
  }
});

test("every shipped diff locale covers the labels and preserves placeholders", async () => {
  const { default: table } = await import("../src/pages/diff/generated/strings.json");
  const { LOCALES } = await import("../scripts/pages/gen-strings.mjs");
  expect(Object.keys(table).sort()).toEqual([...(LOCALES as string[])].sort());
  const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
  for (const local of Object.values(table)) {
    expect(Object.keys(local)).toEqual(Object.keys(table.en));
    for (const key of Object.keys(table.en) as (keyof typeof table.en)[]) {
      expect(local[key].trim()).not.toBe("");
      expect(placeholders(local[key])).toEqual(placeholders(table.en[key]));
    }
  }
});
