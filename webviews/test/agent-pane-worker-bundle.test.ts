// The highlight worker receives resolved grammars from the page. Its standalone script must
// not carry a second copy of the page's language registry through an engine barrel import.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Metafile } from "esbuild";
import { bundledLanguages } from "../src/agent-session/acpmux/shiki";
import { HIGHLIGHTED_LANGUAGES } from "../src/agent-session/acpmux/shikiLanguages";

const work = mkdtempSync(path.join(tmpdir(), "agent-pane-worker-bundle-"));
const output = path.join(work, "highlight-worker.js");
const meta = path.join(work, "metafile.json");

beforeAll(() => {
  const result = spawnSync(
    "bun",
    [
      "scripts/agent-pane/bundle.mjs",
      "node_modules/@pierre/diffs/dist/worker/worker.js",
      "src/agent-session/acpmux/shiki",
      output,
      "--metafile",
      meta,
    ],
    { cwd: path.resolve(import.meta.dir, ".."), encoding: "utf8", timeout: 60_000 },
  );
  expect(result.status, result.stderr).toBe(0);
}, 60_000);

afterAll(() => rmSync(work, { recursive: true, force: true }));

test("the worker ships no duplicate language payloads and needs no module fetches", () => {
  const { outputs } = JSON.parse(readFileSync(meta, "utf8")) as Metafile;
  const worker = Object.values(outputs)[0]!;
  const grammars = Object.entries(worker.inputs)
    .filter(([name, input]) => name.includes("/@shikijs/langs/") && input.bytesInOutput > 0)
    .map(([name]) => name);
  expect(grammars).toEqual([]);
  // Its response policy is default-src 'none': sharing chunks with the page would break it.
  expect(worker.imports).toEqual([]);
});

test("the bundled worker highlights every supported language sent by the page", async () => {
  const worker = new Worker(output);
  let sequence = 0;
  const request = (body: Record<string, unknown>) =>
    new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("highlight worker response timed out")), 10_000);
      worker.onmessage = (event) => {
        clearTimeout(timer);
        resolve(event.data);
      };
      worker.onerror = (event) => {
        clearTimeout(timer);
        reject(new Error(event.message));
      };
      worker.postMessage({ ...body, id: String(sequence++) });
    });
  try {
    const theme = {
      name: "worker-test",
      type: "dark",
      colors: { "editor.foreground": "#ffffff", "editor.background": "#000000" },
      tokenColors: [{ scope: "keyword", settings: { foreground: "#ff0000" } }],
    };
    expect(
      (
        await request({
          type: "initialize",
          preferredHighlighter: "shiki-js",
          renderOptions: { theme: theme.name, tokenizeMaxLineLength: 1000, useTokenTransformer: false },
          resolvedThemes: [theme],
          resolvedLanguages: [],
        })
      ).type,
    ).toBe("success");
    for (const lang of Object.keys(HIGHLIGHTED_LANGUAGES)) {
      const grammar = await bundledLanguages[lang]!();
      const response = await request({
        type: "file",
        file: { name: `example.${lang}`, lang, contents: 'const answer = "hello";\n' },
        resolvedLanguages: [{ name: lang, data: grammar.default }],
      });
      expect(response.type, `${lang}: ${JSON.stringify(response)}`).toBe("success");
      expect(response.requestType).toBe("file");
      expect(JSON.stringify(response.result)).toContain("answer");
    }
  } finally {
    worker.terminate();
  }
}, 60_000);
