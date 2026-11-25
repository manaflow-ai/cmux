// Lints each saved source file with the performance rules (scripts/lint/perf-footguns.json) while the
// dev server runs, so whoever edits webviews live (`cmux live`, `bun run dev`, a modder's own copy)
// sees a footgun on save, in the server log and in the page's console, before any check runs.
// It only warns: nothing here stops a reload. docs/cmux-next/modding-kit.md lists the rules.
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
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
  diagnostics?: { filename: string; code?: string; message: string; labels?: { span?: { line?: number } }[] }[];
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
    rule: d.code?.replace(/^([\w-]+)\(([^)]+)\)$/, "$1/$2") ?? "parse",
    message: d.message,
  }));
}

const DONE = "__cmux_perf_lint_done__";
// One small shell, started with the server, runs each lint: a save only writes a line to it. A
// `spawn` from the hook forked this whole dev server (112-146 ms on Linux), and Vite sends the hot
// update only after the hook returns, so every save reached the page that much later.
const LINTER = `while IFS= read -r f; do "$VP" lint --config "$CONFIG" --format json "$f" 2>/dev/null; printf '\\n%s\\n' "$DONE"; done`;

/** Lints files one at a time in one long-lived shell; `lint` answers in the order it was asked. */
export function perfLinter(vp = VP, config = CONFIG) {
  let child: ChildProcessWithoutNullStreams | undefined;
  let output = "";
  const waiting: ((findings: PerfLintFinding[]) => void)[] = [];
  const start = () => {
    const shell = spawn("/bin/sh", ["-c", LINTER], {
      cwd: ROOT,
      env: { ...process.env, VP: vp, CONFIG: config, DONE },
    });
    shell.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      for (let end = output.indexOf(`\n${DONE}\n`); end >= 0; end = output.indexOf(`\n${DONE}\n`)) {
        const report = output.slice(0, end);
        output = output.slice(end + DONE.length + 2);
        waiting.shift()?.(perfLintFindings(report));
      }
    });
    // A linter that cannot start or stops answers its pending lints with nothing; the next save starts another.
    const stop = () => {
      if (child !== shell) return;
      child = undefined;
      output = "";
      for (const resolve of waiting.splice(0)) resolve([]);
    };
    shell.on("error", stop);
    shell.on("exit", stop);
    shell.stdin.on("error", stop);
    return shell;
  };
  return {
    start() {
      child ??= start();
    },
    lint(file: string): Promise<PerfLintFinding[]> {
      child ??= start();
      return new Promise((resolve) => {
        waiting.push(resolve);
        child!.stdin.write(`${file}\n`);
      });
    },
    close() {
      const shell = child;
      shell?.stdin.end();
      shell?.kill();
    },
  };
}

export function perfLintOnSave(): Plugin {
  // The newest save per file wins: a slower lint of an older save never reports over it.
  const latest = new Map<string, number>();
  const linter = perfLinter();
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
      // Forked now, before the first save, and once: each save only writes a line to it.
      linter.start();
      dev.httpServer?.once("close", () => linter.close());
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
      void linter.lint(file).then((findings) => {
        if (latest.get(file) !== save || !findings.length || !server) return;
        for (const f of findings)
          server.config.logger.warn(`[cmux perf lint] ${f.file}:${f.line} ${f.rule}: ${f.message}`);
        server.ws.send({ type: "custom", event: EVENT, data: findings });
      });
    },
  };
}
