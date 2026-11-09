// Lints each saved source file with the performance rules (scripts/lint/perf-footguns.json) while the
// dev server runs, so whoever edits webviews live (`cmux live`, `bun run dev`, a modder's own copy)
// sees a footgun on save, in the server log and in the page's console, before any check runs.
// It only warns: nothing here stops a reload. docs/cmux-next/modding-kit.md lists the rules.
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin, ViteDevServer } from "vite-plus";

import { devBase } from "./devEntrySrc";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const CONFIG = path.join(ROOT, "scripts/lint/perf-footguns.json");
const VP = path.join(ROOT, "node_modules/.bin/vp");
const CLIENT_ID = "virtual:cmux-perf-lint-client";
const RESOLVED_CLIENT_ID = `\0${CLIENT_ID}`;
const EVENT = "cmux:perf-lint";
const SOURCE = /\.(?:[cm]?[jt]sx?)$/;

export type PerfLintFinding = { file: string; line: number; rule: string; message: string };

type Report = {
  diagnostics?: { filename: string; code: string; message: string; labels?: { span?: { line?: number } }[] }[];
};

/** The findings in `vp lint --format json` output, with paths relative to webviews/. */
export function perfLintFindings(output: string): PerfLintFinding[] {
  const start = output.indexOf("{");
  if (start < 0) return [];
  let report: Report;
  try {
    report = JSON.parse(output.slice(start)) as Report;
  } catch {
    return [];
  }
  return (report.diagnostics ?? []).map((d) => ({
    file: path.relative(ROOT, path.resolve(ROOT, d.filename)),
    line: d.labels?.[0]?.span?.line ?? 0,
    // `cmux-perf(layout-thrash-in-loop)` is the rule `cmux-perf/layout-thrash-in-loop`.
    rule: d.code.replace(/^([\w-]+)\(([^)]+)\)$/, "$1/$2"),
    message: d.message,
  }));
}

function lint(file: string): Promise<PerfLintFinding[]> {
  return new Promise((resolve) => {
    const child = spawn(VP, ["lint", "--config", CONFIG, "--format", "json", file], { cwd: ROOT });
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => (output += chunk.toString()));
    child.on("error", () => resolve([]));
    child.on("close", () => resolve(perfLintFindings(output)));
  });
}

export function perfLintOnSave(): Plugin {
  // The newest save per file wins: a slower lint of an older save never reports over it.
  const latest = new Map<string, number>();
  let server: ViteDevServer | undefined;
  let base = "/";
  return {
    name: "cmux-perf-lint-on-save",
    apply: "serve",
    configResolved(config) {
      base = devBase(config.base);
    },
    configureServer(dev) {
      server = dev;
    },
    resolveId(id) {
      return id === CLIENT_ID ? RESOLVED_CLIENT_ID : undefined;
    },
    load(id) {
      if (id !== RESOLVED_CLIENT_ID) return undefined;
      return `if (import.meta.hot) import.meta.hot.on(${JSON.stringify(EVENT)}, (findings) => {
  for (const f of findings) console.warn(\`[cmux perf lint] \${f.file}:\${f.line} \${f.rule}: \${f.message}\`);
});`;
    },
    transformIndexHtml: () => [
      { tag: "script", attrs: { type: "module", src: `${base}@id/${CLIENT_ID}` }, injectTo: "head" },
    ],
    handleHotUpdate({ file }) {
      if (!SOURCE.test(file) || !file.startsWith(path.join(ROOT, "src") + path.sep)) return;
      const save = (latest.get(file) ?? 0) + 1;
      latest.set(file, save);
      void lint(file).then((findings) => {
        if (latest.get(file) !== save || !findings.length || !server) return;
        for (const f of findings)
          server.config.logger.warn(`[cmux perf lint] ${f.file}:${f.line} ${f.rule}: ${f.message}`);
        server.ws.send({ type: "custom", event: EVENT, data: findings });
      });
    },
  };
}
