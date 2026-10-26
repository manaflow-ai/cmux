// The shared library (scripts/pages/shared-library.mjs): React built once into _shared/react-<hash>.js,
// which every page and the agent pane import by one URL. A bundle's named, default and namespace
// imports and a dependency's CommonJS require() all read the one React the file holds; a default
// import of another of its modules is refused, because the file's default is React's.
import { afterEach, describe, expect, test } from "bun:test";
import { build } from "esbuild";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  LIBRARY_MODULES,
  buildSharedLibrary,
  importsDefault,
  libraryExports,
  librarySource,
} from "../scripts/pages/shared-library.mjs";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

function tempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shared-library-"));
  dirs.push(dir);
  return dir;
}

/** Bundles `files` (written to a temp folder; the first is the entry) with the library beside them. */
async function bundleWithLibrary(files: Record<string, string>) {
  const dir = tempDir();
  for (const [file, contents] of Object.entries(files)) fs.writeFileSync(path.join(dir, file), contents);
  const library = await buildSharedLibrary(dir);
  await build({
    entryPoints: [path.join(dir, Object.keys(files)[0])],
    bundle: true,
    format: "esm",
    platform: "browser",
    outfile: path.join(dir, "out.js"),
    logLevel: "silent",
    define: { "process.env.NODE_ENV": '"production"' },
    plugins: [library.plugin(`./${library.file}`)],
  });
  return { dir, library };
}

describe("the shared library", () => {
  test("exports every name of its modules once, React as its default and each other module's own default", () => {
    const exports = libraryExports();
    expect(Object.keys(exports)).toEqual(LIBRARY_MODULES);
    expect(exports.react).toContain("useState");
    expect(exports["react-dom/client"]).toContain("createRoot");
    const source = librarySource(exports);
    expect(source.match(/\bFragment\b/g)).toHaveLength(1);
    expect(source.match(/\bversion\b/g)).toHaveLength(1);
    expect(source).toContain("export default m0;");
    expect(source).toContain("export const default$react_dom_client = m4;");
  });

  test("named, default, namespace and require() imports read the one React of the file", async () => {
    const { dir, library } = await bundleWithLibrary({
      "main.js": [
        'import React, { createElement, useState } from "react";',
        'import * as Namespace from "react";',
        'import { jsx } from "react/jsx-runtime";',
        'import { c } from "react/compiler-runtime";',
        'import { createPortal } from "react-dom";',
        'import { createRoot } from "react-dom/client";',
        'import viaRequire from "./uses-require.cjs";',
        "export const checks = {",
        "  defaultIsTheModule: React.createElement === createElement,",
        "  namespace: Namespace.useState === useState,",
        "  requireReact: viaRequire.react === React,",
        "  requireDom: viaRequire.dom.createPortal === createPortal,",
        '  functions: [jsx, c, createRoot].every((value) => typeof value === "function"),',
        "};",
      ].join("\n"),
      "uses-require.cjs": 'module.exports = { react: require("react"), dom: require("react-dom") };\n',
    });
    const out = fs.readFileSync(path.join(dir, "out.js"), "utf8");
    // React is not bundled: the bundle imports the library's file.
    expect(out).toContain(`"./${library.file}"`);
    expect(out).not.toContain("react.transitional.element");
    const { checks } = await import(path.join(dir, "out.js"));
    expect(checks).toEqual({
      defaultIsTheModule: true,
      namespace: true,
      requireReact: true,
      requireDom: true,
      functions: true,
    });
  }, 60_000);

  test("a default import of a module other than React is refused", async () => {
    const files = { "main.js": 'import ReactDOM from "react-dom";\nexport const dom = ReactDOM;\n' };
    await expect(bundleWithLibrary(files)).rejects.toThrow(/imports the default of react-dom/);
  }, 60_000);

  test("finds a default import of a module in any form, and nothing else", () => {
    const yes = [
      'import ReactDOM from "react-dom";',
      'import ReactDOM, { flushSync } from "react-dom";',
      "import d,{flushSync as f}from'react-dom'",
      'import ReactDOM, * as All from "react-dom";',
      'import { default as ReactDOM } from "react-dom";',
      'export { default } from "react-dom";',
      'import {\n  flushSync,\n  default as ReactDOM,\n} from "react-dom";',
    ];
    const no = [
      'import { flushSync } from "react-dom";',
      'import * as ReactDOM from "react-dom";',
      'import type ReactDOM from "react-dom";',
      'import ReactDOM from "react-dom/client";',
      'import "react-dom";',
    ];
    for (const source of yes) expect(importsDefault(source, "react-dom"), source).toBe(true);
    for (const source of no) expect(importsDefault(source, "react-dom"), source).toBe(false);
  });
});
