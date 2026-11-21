// The pane benches build the dev entry with Vite (vite.config.acpmux-pane.mjs). That build loads the
// strings as the shipped page does (scripts/cmux-next/build-agent-pane-web.sh): locales/en.js and
// locales/loader.js before the module, so dev.tsx never pulls in its whole 21-locale table and the
// benches' chat open does not parse 3.5 MiB of strings the app never loads.
import { expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { paneLocales } from "../scripts/agent-pane/paneLocales.mjs";

const table = { en: { "a.b": "Hi" }, de: { "a.b": "Hallo" } };

function plugin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pane-locales-"));
  const file = path.join(dir, "strings.json");
  fs.writeFileSync(file, JSON.stringify(table));
  return paneLocales(file);
}

test("build only: the dev server keeps the whole table", () => {
  expect(plugin().apply).toBe("build");
});

test("English and the loader run before the module", () => {
  const html = `<head>\n    <script type="module" crossorigin src="/assets/index.js"></script>\n</head>`;
  const out = plugin().transformIndexHtml.handler(html);
  const en = out.indexOf('<script src="locales/en.js"></script>');
  const loader = out.indexOf('<script src="locales/loader.js"></script>');
  expect(en).toBeGreaterThan(-1);
  expect(loader).toBeGreaterThan(en);
  expect(out.indexOf('<script type="module"')).toBeGreaterThan(loader);
});

test("every locale ships as its own script beside the loader", () => {
  const emitted: { fileName: string; source: string }[] = [];
  plugin().generateBundle.call({ emitFile: (file: { fileName: string; source: string }) => emitted.push(file) });
  expect(emitted.map((file) => file.fileName).sort()).toEqual(["locales/de.js", "locales/en.js", "locales/loader.js"]);
  const de = emitted.find((file) => file.fileName === "locales/de.js")!.source;
  const prefix = '(window.__cmuxPaneStrings = window.__cmuxPaneStrings || {})["de"] = ';
  expect(de.startsWith(prefix)).toBe(true);
  expect(JSON.parse(de.slice(prefix.length).replace(/;\n$/, ""))).toEqual(table.de);
});
