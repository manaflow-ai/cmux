import { expect, test } from "bun:test";
import { DiffLabelCatalog } from "../src/diff/labelCatalog";
import { diffLocaleLoaders } from "../src/pages/diff/generated/localeLoaders";

test("only the selected locale chunk loads, including concurrent first renders", async () => {
  for (const locale of ["ja", "de"]) {
    const loaded: string[] = [];
    const catalog = new DiffLabelCatalog(
      Object.fromEntries(
        Object.entries(diffLocaleLoaders).map(([code, loader]) => [
          code,
          () => {
            loaded.push(code);
            return loader();
          },
        ]),
      ),
    );
    expect(() => catalog.strings(locale)).toThrow("must load before rendering");
    await Promise.all([catalog.load(locale), catalog.load(locale)]);
    await catalog.load(locale);
    expect(loaded).toEqual([locale]);
    expect(catalog.strings(locale).t("diffViewer.hideFiles")).toBe(
      locale === "ja" ? "ファイルを隠す" : "Dateien ausblenden",
    );
  }
});

test("the first render waits for translation and missing keys use English", async () => {
  let finish!: (value: { default: Record<string, string> }) => void;
  const catalog = new DiffLabelCatalog({
    ja: () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  });
  const rendering = catalog.load("ja").then(() => catalog.strings("ja").t("diffViewer.hideFiles"));
  expect(() => catalog.strings("ja")).toThrow("must load before rendering");
  finish({ default: { "diffViewer.hideFiles": "ファイルを隠す" } });
  expect(await rendering).toBe("ファイルを隠す");
  expect(catalog.strings("ja").t("diffViewer.showFiles")).toBe("Show files");
});

test("a failed locale chunk prevents rendering and can be retried", async () => {
  let calls = 0;
  const catalog = new DiffLabelCatalog({
    de: async () => {
      if (++calls === 1) throw new Error("offline");
      return { default: { "diffViewer.hideFiles": "Dateien ausblenden" } };
    },
  });
  await expect(catalog.load("de")).rejects.toThrow("offline");
  expect(() => catalog.strings("de")).toThrow("must load before rendering");
  await catalog.load("de");
  expect(catalog.strings("de").t("diffViewer.hideFiles")).toBe("Dateien ausblenden");
});
