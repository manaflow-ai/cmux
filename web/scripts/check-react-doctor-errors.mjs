import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const executable = process.platform === "win32" ? "npm.cmd" : "npm";

const result = spawnSync(
  executable,
  [
    "exec",
    "--yes",
    "--package",
    "react-doctor@0.2.14",
    "--",
    "react-doctor",
    ".",
    "--full",
    "--json",
    "--json-compact",
    "--no-score",
    "--fail-on",
    "none",
  ],
  {
    cwd: webRoot,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 180_000,
  },
);

if (result.error) {
  throw result.error;
}

if (result.status !== 0) {
  process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}

let report;
try {
  report = JSON.parse(result.stdout);
} catch (error) {
  process.stderr.write(result.stderr);
  throw new Error(`React Doctor returned invalid JSON: ${error.message}`);
}

const diagnostics = (report.projects ?? []).flatMap(
  (project) => project.diagnostics ?? [],
);

// React Doctor has changed these diagnostics between errors and warnings.
// Match the accepted rule/file pairs so the regression gate stays stable.
const openGraphImageModule = /(?:^|\/)(?:opengraph-image|open-graph-image)\.tsx$/;
const blockedDiagnostics = diagnostics.filter(({ filePath, rule }) => {
  if (
    filePath === "app/[locale]/testimonials.tsx" &&
    rule === "only-export-components"
  ) {
    return true;
  }

  return (
    openGraphImageModule.test(filePath) &&
    (rule === "only-export-components" || rule.endsWith("alt-text"))
  );
});

if (blockedDiagnostics.length > 0) {
  console.error(
    `React Doctor found ${blockedDiagnostics.length} blocked error-level regression(s):`,
  );
  for (const diagnostic of blockedDiagnostics) {
    console.error(
      `- ${diagnostic.filePath}:${diagnostic.line} [${diagnostic.rule}] ${diagnostic.message}`,
    );
  }
  process.exit(1);
}

console.log("React Doctor found 0 blocked error-level regressions.");
