// The gallery's controls live in the URL: a query reads the same in the web gallery and in the
// native one (schemas/gallery/env-vectors.json, which CmuxNextGalleryTests replays too), and
// writing then reading a value set gives it back. Plus the pseudo-locales and media emulation.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { DEFAULT_ENV, readEnv, writeEnv, type GalleryEnv } from "../src/gallery/env";
import { rewriteMediaQuery } from "../src/gallery/frame/media";
import { addPseudoLocales, pseudoText } from "../src/gallery/pseudo";

const vectors = JSON.parse(
  fs.readFileSync(path.join(import.meta.dir, "../../schemas/gallery/env-vectors.json"), "utf8"),
) as { vectors: { query: Record<string, string>; env: GalleryEnv }[] };

describe("gallery controls", () => {
  test("each shared vector's query reads as its value set", () => {
    expect(vectors.vectors.length).toBeGreaterThan(5);
    for (const vector of vectors.vectors) expect(readEnv(new URLSearchParams(vector.query))).toEqual(vector.env);
  });

  test("a value set survives the URL, and the defaults leave it empty", () => {
    expect(writeEnv(DEFAULT_ENV).toString()).toBe("");
    const env: GalleryEnv = {
      ...DEFAULT_ENV,
      locale: "ar-XB",
      colorScheme: "light",
      theme: "Catppuccin Latte",
      fontFamily: '"SF Pro Text", system-ui',
      fontSize: 16,
      scale: 1.25,
      width: 1000,
      reducedMotion: true,
      dynamicSize: "xlarge",
      windowKey: "inactive",
    };
    expect(readEnv(writeEnv(env))).toEqual(env);
  });

  test("pseudo-locales keep placeholders and change every letter", () => {
    expect(pseudoText("Edited {count} files", "en-XA")).toMatch(/^\[Éðíţéð \{count\} ƒíļéš ·+\]$/);
    expect(pseudoText("%1$@ of %2$@", "en-XA")).toContain("%1$@");
    expect(pseudoText("Send", "ar-XB")).toBe("‫Send‬");
    const table: Record<string, Record<string, string>> = { en: { a: "Stop" }, ja: { a: "停止" } };
    addPseudoLocales(table);
    expect(Object.keys(table).sort()).toEqual(["ar-XB", "en", "en-XA", "ja"]);
  });

  test("emulated media features rewrite only their own tests", () => {
    const dark = {
      "prefers-color-scheme": "dark",
      "prefers-reduced-motion": "reduce",
      "prefers-contrast": "no-preference",
    } as const;
    expect(rewriteMediaQuery("(prefers-color-scheme: dark)", dark)).toBe("(min-width: 0px)");
    expect(rewriteMediaQuery("(prefers-color-scheme: light)", dark)).toBe("(min-resolution: 999999dppx)");
    expect(rewriteMediaQuery("screen and (prefers-reduced-motion)", dark)).toBe("screen and (min-width: 0px)");
    expect(rewriteMediaQuery("(max-width: 600px)", dark)).toBe("(max-width: 600px)");
  });
});
