import { describe, expect, test } from "bun:test";
import { factorSharedCss } from "./factor-shared-css.mjs";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import postcss from "postcss";
import focusRingGate from "../postcss/focusRingGate.mjs";

describe("factorSharedCss", () => {
  test("factors real opted-in and held page CSS without changing either cascade", async () => {
    const styles = await Promise.all(
      ["certificate", "feed"].map(async (page) => {
        const result = await build({
          entryPoints: [fileURLToPath(new URL(`../../src/pages/${page}/main.tsx`, import.meta.url))],
          outfile: `/tmp/material-prefix-${page}/styles.js`,
          bundle: true,
          write: false,
          format: "esm",
          platform: "browser",
          target: "es2022",
          define: { "process.env.NODE_ENV": '"production"' },
          minify: true,
          legalComments: "none",
          loader: { ".png": "dataurl", ".woff2": "dataurl" },
          logLevel: "silent",
        });
        const css = result.outputFiles.find((file) => file.path.endsWith(".css"));
        expect(css).toBeDefined();
        return (await postcss([focusRingGate()]).process(css.text, { from: undefined })).css;
      }),
    );
    const { shared, remainders } = factorSharedCss(styles);
    expect(shared.length).toBeGreaterThan(0);
    expect(remainders.map((tail) => shared + tail)).toEqual(styles);
    expect(remainders[0]).toContain("data-transient-material");
    expect(styles[1]).not.toContain("data-transient-material");
  });

  test("keeps nested at-rules intact", () => {
    const styles = [
      ".shared{color:red}@media (width > 1px){.shared{display:block}}.one{color:blue}",
      ".shared{color:red}@media (width > 1px){.shared{display:block}}.two{color:green}",
    ];
    const { shared, remainders } = factorSharedCss(styles);
    expect(shared).toBe(".shared{color:red}@media (width > 1px){.shared{display:block}}");
    expect(remainders).toEqual([".one{color:blue}", ".two{color:green}"]);
    expect(remainders.map((tail) => shared + tail)).toEqual(styles);
  });

  test("rejects a shared prefix with a document-relative URL", () => {
    expect(() =>
      factorSharedCss([".shared{background:url(font.woff2)}.one{}", ".shared{background:url(font.woff2)}.two{}"]),
    ).toThrow("relative URL");
  });
});
