// The esbuild plugin that runs the React Compiler over first-party sources, shared by
// bundle.mjs (the shipped agent pane and pages) and tests that run the compiled output.
//
// babel: babel-plugin-react-compiler; TypeScript and JSX are only parsed there, so esbuild
// still strips the types. oxc: oxc-transform-react, which strips the types and keeps JSX; a
// fatal result fails the build. Components the compiler skips or bails out on go to
// `onDiagnostic`, and each compiled function (Babel) or file (Oxc) to `onCompiled`.
import { transformAsync } from "@babel/core";
import { transformSync } from "oxc-transform-react";
import crypto from "node:crypto";
import fs from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { REACT_COMPILER_TARGET } from "../../reactCompiler.mjs";

function lineOf(source, offset) {
  let line = 1;
  for (let index = 0; index < offset && index < source.length; index++) if (source.charCodeAt(index) === 10) line++;
  return line;
}

async function compileWithBabel(file, relative, source, onCompiled, onDiagnostic) {
  const result = await transformAsync(source, {
    filename: file,
    babelrc: false,
    configFile: false,
    sourceMaps: false,
    compact: false,
    retainLines: false,
    parserOpts: { plugins: ["jsx", "typescript"] },
    plugins: [
      [
        "babel-plugin-react-compiler",
        {
          target: REACT_COMPILER_TARGET,
          logger: {
            logEvent(_filename, event) {
              if (event.kind === "CompileSuccess") onCompiled(`${relative}:${event.fnName ?? "anonymous"}`);
              if (event.kind === "CompileError" || event.kind === "CompileSkip" || event.kind === "PipelineError") {
                const detail = event.detail ?? {};
                onDiagnostic({
                  file: relative,
                  kind: event.kind,
                  function: event.fnName ?? null,
                  line: event.fnLoc?.start?.line ?? detail.loc?.start?.line ?? null,
                  reason: String(detail.reason ?? detail.options?.reason ?? event.reason ?? event.data ?? "unknown"),
                });
              }
            },
          },
        },
      ],
    ],
  });
  return { contents: result?.code ?? source, loader: file.endsWith(".tsx") ? "tsx" : "ts" };
}

// Oxc reports diagnostics per finding, not per function, and has no success event.
function compileWithOxc(file, relative, source, onCompiled, onDiagnostic) {
  const result = transformSync(file, source, {
    lang: file.endsWith(".tsx") ? "tsx" : "ts",
    sourceType: "module",
    jsx: "preserve",
    reactCompiler: { target: REACT_COMPILER_TARGET },
  });
  for (const error of result.errors) {
    onDiagnostic({
      file: relative,
      kind: error.severity,
      function: null,
      line: error.labels[0] ? lineOf(source, error.labels[0].start) : null,
      reason: error.message,
    });
  }
  if (result.fatal) {
    const detail = result.errors.map((error) => error.codeframe ?? error.message).join("\n\n");
    throw new Error(`React Compiler (oxc) failed on ${relative}:\n${detail || "unknown error"}`);
  }
  onCompiled(relative);
  return { contents: result.code, loader: "jsx" };
}

/**
 * @param {{ mode: "babel" | "oxc", srcRoot: string, onCompiled?: (id: string) => void,
 *   onDiagnostic?: (diagnostic: object) => void, cacheDir?: string }} options
 */
export function reactCompilerPlugin({
  mode,
  srcRoot,
  onCompiled = () => {},
  onDiagnostic = () => {},
  cacheDir = process.env.CMUX_VITE_TRANSFORM_CACHE,
}) {
  const uncached = mode === "oxc" ? compileWithOxc : compileWithBabel;
  const compile = cacheDir ? cachedCompile(uncached, mode, srcRoot, cacheDir) : uncached;
  return {
    name: "react-compiler",
    setup(context) {
      context.onLoad({ filter: /\.(tsx|ts)$/ }, async (args) => {
        if (!args.path.startsWith(srcRoot + path.sep) || args.path.endsWith(".d.ts")) return undefined;
        const source = await readFile(args.path, "utf8");
        return compile(args.path, path.relative(srcRoot, args.path), source, onCompiled, onDiagnostic);
      });
    },
  };
}

/**
 * The compiler's output kept on disk in CMUX_VITE_TRANSFORM_CACHE when that is set, as reactCompiler.mjs
 * keeps Vite's. The Babel pass is most of an agent pane bundle: build-agent-pane-web.sh took 60 s in
 * cmux-tui-build-package.yml's x86_64 thin leg (job 140256154463, 1,515 functions compiled), and the
 * sources change little between runs. The key is the mode, the target, the lockfile, the file (relative
 * to src/, so a cache written in another checkout path hits) and its exact source, so a hit is the output
 * the pass would make. Its compiled functions and diagnostics replay with it, so the bundle's report is
 * the same. Entries live under bundle/, beside Vite's. Unset, nothing changes.
 */
function cachedCompile(compile, mode, srcRoot, cacheDir) {
  let lock = "";
  try {
    lock = crypto
      .createHash("sha256")
      .update(fs.readFileSync(path.join(srcRoot, "..", "bun.lock")))
      .digest("hex");
  } catch {}
  const salt = JSON.stringify(["bundle-v1", mode, REACT_COMPILER_TARGET, lock]);
  return async (file, relative, source, onCompiled, onDiagnostic) => {
    const key = crypto
      .createHash("sha256")
      .update(`${salt}\0${relative}\0`)
      .update(source)
      .digest("hex");
    const entry = path.join(cacheDir, "bundle", key.slice(0, 2), `${key}.json`);
    try {
      const hit = JSON.parse(fs.readFileSync(entry, "utf8"));
      for (const id of hit.compiled) onCompiled(id);
      for (const diagnostic of hit.diagnostics) onDiagnostic(diagnostic);
      // A hit is still in use: CI keeps the cache across runs and drops entries no run has read lately.
      try {
        const now = new Date();
        fs.utimesSync(entry, now, now);
      } catch {}
      return hit.result;
    } catch {}
    const compiled = [];
    const diagnostics = [];
    const result = await compile(
      file,
      relative,
      source,
      (id) => {
        compiled.push(id);
        onCompiled(id);
      },
      (diagnostic) => {
        diagnostics.push(diagnostic);
        onDiagnostic(diagnostic);
      },
    );
    // Written whole and renamed into place: another bundle may read the same key at once.
    try {
      fs.mkdirSync(path.dirname(entry), { recursive: true });
      const temporary = `${entry}.${process.pid}.${crypto.randomUUID()}`;
      fs.writeFileSync(temporary, JSON.stringify({ result, compiled, diagnostics }));
      fs.renameSync(temporary, entry);
    } catch {}
    return result;
  };
}
