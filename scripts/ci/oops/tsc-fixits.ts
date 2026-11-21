// tsc-fixits: the TypeScript language service's own fix for each type error, when it has exactly one safe fix.
//
//   bun scripts/ci/oops/tsc-fixits.ts --project DIR < errors.json
//
// scripts/ci/oops/fixit_compile.py (ci-oops part 0a, fixer `fixit-compile`) runs this after a failed typecheck.
// stdin is the errors it read from the log: [{file, line, col, code, message}], file relative to DIR, line and col
// 1-based. For each, the tsconfig under DIR whose program holds the file (following project references) gets a
// language service, which must report the same error code at that position; then getCodeFixesAtPosition answers.
// An error counts as fixable only when the answer is exactly one fix, its fixName is on SAFE_FIXES (what the
// compiler knows without a guess: no spelling correction, no @ts-ignore, no new declaration), and it carries no
// command. stdout: {"errors", "fixable", "unfixable": [why...], "edits": {absolute path: [[start, end, text]...]}},
// offsets in UTF-16 code units of the file as it is on disk. The TypeScript used is DIR's own (its node_modules).
import { createRequire } from "node:module";
import * as fs from "node:fs";
import * as path from "node:path";

type TsError = { file: string; line: number; col: number; code: number; message?: string };
type Edit = [number, number, string];

// fixName values from TypeScript's codefixes (src/services/codefixes/*.ts): each adds or rewrites only what the
// error names, and is offered alone only when there is one way to do it.
export const SAFE_FIXES = new Set([
  "import", // a missing import, when exactly one module exports the name
  "fixOverrideModifier", // add or remove `override` (noImplicitOverride, TS4114/TS4113)
  "convertToTypeOnlyImport", // verbatimModuleSyntax / isolatedModules type-only imports (TS1484, TS1371)
  "convertToTypeOnlyExport", // the same for re-exports (TS1205)
  "fixAwaitInSyncFunction", // an `await` in a function that is not async (TS1308)
]);

function argValue(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function readStdin(): string {
  return fs.readFileSync(0, "utf8");
}

export function main(): void {
  const project = path.resolve(argValue("--project") ?? process.cwd());
  const require = createRequire(path.join(project, "package.json"));
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const ts: typeof import("typescript") = require("typescript");
  const errors: TsError[] = JSON.parse(readStdin() || "[]");

  const services = new Map<string, import("typescript").LanguageService | null>();
  const configFor = new Map<string, string | null>();

  function parse(configPath: string): import("typescript").ParsedCommandLine | undefined {
    return (
      ts.getParsedCommandLineOfConfigFile(
        configPath,
        {},
        {
          ...ts.sys,
          onUnRecoverableConfigFileDiagnostic: () => undefined,
        },
      ) ?? undefined
    );
  }

  // Every tsconfig reachable from DIR's tsconfig.json through references, in order.
  const configs: { path: string; parsed: import("typescript").ParsedCommandLine }[] = [];
  const seen = new Set<string>();
  function walk(configPath: string): void {
    const real = path.resolve(configPath);
    if (seen.has(real) || !fs.existsSync(real)) return;
    seen.add(real);
    const parsed = parse(real);
    if (!parsed) return;
    configs.push({ path: real, parsed });
    for (const ref of parsed.projectReferences ?? []) {
      walk(ts.resolveProjectReferencePath(ref));
    }
  }
  walk(path.join(project, "tsconfig.json"));

  function serviceFor(file: string): import("typescript").LanguageService | null {
    if (!configFor.has(file)) {
      const hit = configs.find((c) => c.parsed.fileNames.some((f) => path.resolve(f) === file));
      configFor.set(file, hit ? hit.path : null);
    }
    const configPath = configFor.get(file);
    if (!configPath) return null;
    if (!services.has(configPath)) {
      const parsed = configs.find((c) => c.path === configPath)!.parsed;
      const host: import("typescript").LanguageServiceHost = {
        getCompilationSettings: () => parsed.options,
        getScriptFileNames: () => parsed.fileNames,
        getScriptVersion: () => "0",
        getScriptSnapshot: (name) =>
          fs.existsSync(name) ? ts.ScriptSnapshot.fromString(fs.readFileSync(name, "utf8")) : undefined,
        getCurrentDirectory: () => path.dirname(configPath),
        getDefaultLibFileName: (options) => ts.getDefaultLibFilePath(options),
        fileExists: ts.sys.fileExists,
        readFile: ts.sys.readFile,
        readDirectory: ts.sys.readDirectory,
        directoryExists: ts.sys.directoryExists,
        getDirectories: ts.sys.getDirectories,
        getProjectReferences: () => parsed.projectReferences,
      };
      services.set(configPath, ts.createLanguageService(host, ts.createDocumentRegistry()));
    }
    return services.get(configPath) ?? null;
  }

  const unfixable: string[] = [];
  const edits: Record<string, Edit[]> = {};
  let fixable = 0;
  for (const err of errors) {
    const label = `${err.file}(${err.line},${err.col}): TS${err.code}`;
    const file = path.resolve(project, err.file);
    const service = serviceFor(file);
    const program = service?.getProgram();
    const source = program?.getSourceFile(file);
    if (!service || !source) {
      unfixable.push(`${label} (no tsconfig under the project holds this file)`);
      continue;
    }
    let start: number;
    try {
      start = ts.getPositionOfLineAndCharacter(source, err.line - 1, err.col - 1);
    } catch {
      unfixable.push(`${label} (the position is not in the file)`);
      continue;
    }
    const diags = [...service.getSyntacticDiagnostics(file), ...service.getSemanticDiagnostics(file)];
    const diag = diags.find((d) => d.start === start && d.code === err.code);
    if (!diag || diag.length === undefined) {
      unfixable.push(`${label} (the language service does not report this error here)`);
      continue;
    }
    const fixes = service.getCodeFixesAtPosition(
      file,
      start,
      start + diag.length,
      [err.code],
      ts.getDefaultFormatCodeSettings(),
      { quotePreference: "auto", importModuleSpecifierPreference: "shortest" },
    );
    if (fixes.length !== 1) {
      unfixable.push(`${label} (${fixes.length === 0 ? "no fix" : `${fixes.length} fixes: a choice`})`);
      continue;
    }
    const [fix] = fixes;
    if (!SAFE_FIXES.has(fix.fixName) || fix.commands?.length) {
      unfixable.push(`${label} (fix ${fix.fixName} is not on the safe list)`);
      continue;
    }
    for (const change of fix.changes) {
      const target = path.resolve(change.fileName);
      const list = (edits[target] ??= []);
      for (const t of change.textChanges) {
        const edit: Edit = [t.span.start, t.span.start + t.span.length, t.newText];
        if (!list.some((e) => e[0] === edit[0] && e[1] === edit[1] && e[2] === edit[2])) list.push(edit);
      }
    }
    fixable += 1;
  }
  process.stdout.write(JSON.stringify({ errors: errors.length, fixable, unfixable, edits }) + "\n");
}

if (import.meta.main) {
  main();
}
