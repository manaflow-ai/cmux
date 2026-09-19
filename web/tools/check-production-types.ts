import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const require = createRequire(import.meta.url);
const next = require.resolve("next/dist/bin/next");
const tsgo = join(dirname(require.resolve("@typescript/native-preview/package.json")), "bin/tsgo.js");

/** Keep production builds gated by the same native compiler as full CI. */
export async function checkProductionTypes(projectDir: string): Promise<void> {
  const started = performance.now();
  try {
    // Generate Next's route validators and next-env.d.ts even on a fresh clone.
    // typegen does not invoke this production-compile hook.
    await run(process.execPath, [next, "typegen"], { cwd: projectDir });
    await run(process.execPath, [tsgo, "--project", "tsconfig.next.json", "--noEmit"], {
      cwd: projectDir,
      maxBuffer: 8 * 1024 * 1024,
    });
  } catch (error) {
    const result = error as { stdout?: string; stderr?: string };
    if (result.stdout) process.stderr.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    throw error;
  }
  console.log(`Production types checked with tsgo in ${((performance.now() - started) / 1000).toFixed(2)}s`);
}
