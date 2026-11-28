// The esbuild plugin that runs the React Compiler over first-party sources, shared by
// bundle.mjs (the shipped agent pane and pages) and tests that run the compiled output.
//
// babel: babel-plugin-react-compiler; TypeScript and JSX are only parsed there, so esbuild
// still strips the types. oxc: oxc-transform-react, which strips the types and keeps JSX; a
// fatal result fails the build. Components the compiler skips or bails out on go to
// `onDiagnostic`, and each compiled function (Babel) or file (Oxc) to `onCompiled`.
import { transformAsync } from "@babel/core";
import { transformSync } from "oxc-transform-react";
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
 *   onDiagnostic?: (diagnostic: object) => void }} options
 */
export function reactCompilerPlugin({ mode, srcRoot, onCompiled = () => {}, onDiagnostic = () => {} }) {
  const compile = mode === "oxc" ? compileWithOxc : compileWithBabel;
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
