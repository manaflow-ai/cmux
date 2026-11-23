// pack-pages.mjs (CMUX-570, app size): pages outside --keep get their entry moved into __shared and
// every script no kept page reaches is stored raw-deflated; what Home loads stays as it was.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { inflateRawSync } from "node:zlib";
import { moveEntry, PACKED_SUFFIX, packPages } from "../scripts/pages/pack-pages.mjs";

const BIG = "x".repeat(4096);

function tree() {
  const out = mkdtempSync(path.join(tmpdir(), "pack-pages-"));
  const file = (name: string, text: string) => {
    mkdirSync(path.dirname(path.join(out, name)), { recursive: true });
    writeFileSync(path.join(out, name), text);
  };
  const html = () =>
    `<!doctype html><link rel="modulepreload" href="../__shared/chunk-common.js"><script type="module">import "./app.js";</script>`;
  file("home/index.html", html());
  file("home/app.js", `import "../__shared/chunk-common.js"; import("../__shared/chunk-lazy.js"); // ${BIG}`);
  file("settings/index.html", html());
  file("settings/app.js", `import "../__shared/chunk-common.js"; import "../__shared/chunk-settings.js"; // ${BIG}`);
  file("__shared/chunk-common.js", `export const common = 1; // ${BIG}`);
  file("__shared/chunk-lazy.js", `export const lazy = 1; // ${BIG}`);
  file("__shared/chunk-settings.js", `export const settings = 1; // ${BIG}`);
  file("__shared/tiny.js", "1");
  const output = (imports: string[]) => ({ imports: imports.map((item) => ({ path: path.join(out, item) })) });
  const metafile = {
    outputs: {
      [path.join(out, "home/app.js")]: output(["__shared/chunk-common.js", "__shared/chunk-lazy.js"]),
      [path.join(out, "settings/app.js")]: output(["__shared/chunk-common.js", "__shared/chunk-settings.js"]),
      [path.join(out, "__shared/chunk-common.js")]: output([]),
      [path.join(out, "__shared/chunk-lazy.js")]: output([]),
      [path.join(out, "__shared/chunk-settings.js")]: output([]),
      [path.join(out, "__shared/tiny.js")]: output([]),
    },
  };
  return { out, metafile };
}

describe("pack-pages", () => {
  test("packs what only other pages load and keeps what Home loads", () => {
    const { out, metafile } = tree();
    const settingsEntry = readFileSync(path.join(out, "settings/app.js"));
    const result = packPages({ outdir: out, metafile, keep: ["home"], pages: ["home", "settings"] });
    expect(result.moved).toBe(1);
    expect(result.files).toBe(2);
    expect(result.stored).toBeLessThan(result.raw);

    // Home: untouched, and everything it loads (lazy chunks too) stays plain.
    expect(readFileSync(path.join(out, "home/index.html"), "utf8")).toContain('import "./app.js";');
    for (const name of ["home/app.js", "__shared/chunk-common.js", "__shared/chunk-lazy.js"]) {
      expect(existsSync(path.join(out, name))).toBe(true);
    }
    // Settings: its document imports its entry from __shared, which is packed with its own chunk.
    expect(readFileSync(path.join(out, "settings/index.html"), "utf8")).toContain(
      'import "../__shared/page-settings.js";',
    );
    expect(existsSync(path.join(out, "settings/app.js"))).toBe(false);
    const packed = path.join(out, "__shared/page-settings.js" + PACKED_SUFFIX);
    expect(inflateRawSync(readFileSync(packed)).equals(settingsEntry)).toBe(true);
    expect(existsSync(path.join(out, "__shared/chunk-settings.js" + PACKED_SUFFIX))).toBe(true);
    // A file deflate cannot shrink stays plain.
    expect(existsSync(path.join(out, "__shared/tiny.js"))).toBe(true);
  });

  test("refuses an entry that resolves a file beside itself", () => {
    const { out } = tree();
    writeFileSync(path.join(out, "settings/app.js"), 'import "./worker.js";');
    expect(() => moveEntry(out, "settings")).toThrow(/beside itself/);
    writeFileSync(path.join(out, "settings/app.js"), "new URL('x', import.meta.url);");
    expect(() => moveEntry(out, "settings")).toThrow(/beside itself/);
  });

  test("refuses a document that does not import its entry exactly once", () => {
    const { out } = tree();
    writeFileSync(path.join(out, "settings/index.html"), "<!doctype html>");
    expect(() => moveEntry(out, "settings")).toThrow(/exactly once/);
  });

  test("refuses a kept page the metafile does not know", () => {
    const { out, metafile } = tree();
    expect(() => packPages({ outdir: out, metafile, keep: ["home", "nope"], pages: ["home"] })).toThrow(
      /kept page nope/,
    );
  });
});
