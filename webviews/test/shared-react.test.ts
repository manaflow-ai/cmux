// The one shared React (scripts/shared/shared-react.mjs) that every web tree imports from
// cmux-page://cmux.shared/: one deterministic file, and a bundle built against it, ES imports and
// CommonJS requires alike, runs on that one React (hooks work across react, react-dom/server and a
// CommonJS dependency, which they would not with two copies).
import { afterAll, describe, expect, test } from "bun:test";
import { build } from "esbuild";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  buildSharedReact,
  exportNames,
  SHARED_ORIGIN,
  SHARED_REACT_ENTRIES,
  sharedImports,
  sharedReactEsbuildPlugin,
  specifierModule,
} from "../scripts/shared/shared-react.mjs";

const work = fs.mkdtempSync(path.join(os.tmpdir(), "shared-react-"));
afterAll(() => fs.rmSync(work, { recursive: true, force: true }));
const webviews = path.resolve(import.meta.dir, "..");

describe("shared React", () => {
  test("is one content-hashed file at one cmux.shared URL, the same on every build", async () => {
    const first = await buildSharedReact();
    const second = await buildSharedReact();
    expect(first.name).toMatch(/^react-[A-Z0-9]+\.js$/);
    expect(first.url).toBe(SHARED_ORIGIN + first.name);
    expect(second.name).toBe(first.name);
    expect(Buffer.from(second.bytes).equals(Buffer.from(first.bytes))).toBe(true);
    // Nothing else: no chunk another run would have to know.
    expect(sharedImports(Buffer.from(first.bytes).toString("utf8"))).toEqual([]);
  });

  test("each specifier's module re-exports its names from the shared URL", () => {
    const react = SHARED_REACT_ENTRIES[0];
    const names = exportNames(react);
    expect(names[0]).toBe("default");
    expect(names).toContain("useState");
    const module = specifierModule("react/jsx-runtime", "cmux-page://cmux.shared/react-X.js");
    expect(module).toContain("react_jsx_runtime$jsx as jsx");
    expect(module).toContain('from "cmux-page://cmux.shared/react-X.js"');
  });

  test("a bundle built against it runs on that one React", async () => {
    const shared = await buildSharedReact();
    const sharedFile = path.join(work, shared.name);
    fs.writeFileSync(sharedFile, shared.bytes);
    const url = pathToFileURL(sharedFile).href;
    const entry = path.join(webviews, "test", "fixtures", "shared-react-consumer.tsx");
    const outfile = path.join(work, "consumer.js");
    await build({
      absWorkingDir: webviews,
      entryPoints: [entry],
      bundle: true,
      format: "esm",
      platform: "browser",
      target: "es2022",
      jsx: "automatic",
      define: { "process.env.NODE_ENV": '"production"' },
      outfile,
      logLevel: "silent",
      plugins: [sharedReactEsbuildPlugin(url)],
    });
    const text = fs.readFileSync(outfile, "utf8");
    // React itself is not in the bundle: only imports of the shared file.
    expect(text).toContain(JSON.stringify(url));
    expect(text).not.toMatch(/__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE\s*=[^=]/);
    const { render } = await import(pathToFileURL(outfile).href);
    expect(render()).toBe("<p>count 1 store 7</p>");
  });
});
