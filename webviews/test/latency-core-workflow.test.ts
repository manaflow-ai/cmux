import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const workflow = readFileSync(path.join(import.meta.dir, "../../.github/workflows/cmux-next-web-bundles.yml"), "utf8");
const step = workflow.split("      - name: Measure\n")[1].split("      - name:")[0];
const run = step.split("        run: ")[1].trimEnd();
const command = run.startsWith("|\n")
  ? run
      .slice(2)
      .split("\n")
      .map((line) => line.slice(10))
      .join("\n")
  : run;

for (const missingBase of [false, true])
  test(`shallow topic dispatch ${missingBase ? "fails without a verified base" : "records the fetched base and exact head"}`, () => {
    const dir = mkdtempSync(path.join(tmpdir(), "latency-workflow-"));
    const source = path.join(dir, "source");
    const checkout = path.join(dir, "checkout");
    const git = (cwd: string, ...args: string[]) => {
      const result = Bun.spawnSync(
        [
          "git",
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "user.name=fixture",
          "-c",
          "user.email=fixture@example.com",
          ...args,
        ],
        { cwd },
      );
      if (result.exitCode) throw new Error(result.stderr.toString());
      return result.stdout.toString().trim();
    };
    try {
      mkdirSync(source);
      git(source, "init", "-b", "feat-cmux-next");
      git(source, "commit", "--allow-empty", "-m", "common");
      git(source, "branch", "topic");
      git(source, "commit", "--allow-empty", "-m", "base advances");
      const base = git(source, "rev-parse", "HEAD");
      git(source, "checkout", "topic");
      git(source, "commit", "--allow-empty", "-m", "topic change");
      const head = git(source, "rev-parse", "HEAD");
      if (missingBase) git(source, "branch", "-D", "feat-cmux-next");
      git(dir, "clone", "--depth=1", "--single-branch", "--branch", "topic", `file://${source}`, checkout);
      expect(git(checkout, "rev-parse", "--is-shallow-repository")).toBe("true");
      const bin = path.join(dir, "bin");
      mkdirSync(bin);
      mkdirSync(path.join(checkout, "webviews"));
      // Exercise the caller's real shell and git preparation, replacing only the browser benchmark.
      writeFileSync(
        path.join(bin, "bun"),
        `#!/bin/bash
set -euo pipefail
base=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --base ]; then shift; base="$1"; fi
  shift
done
if [ -z "$base" ]; then base=$(git merge-base HEAD origin/feat-cmux-next); fi
base=$(git rev-parse --verify "$base^{commit}")
printf '{"source":{"head":"%s","base":"%s"}}' "$(git rev-parse HEAD)" "$base" > latency-results.json
`,
      );
      chmodSync(path.join(bin, "bun"), 0o755);
      const result = Bun.spawnSync(["bash", "-euo", "pipefail", "-c", command], {
        cwd: path.join(checkout, "webviews"),
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      });
      const artifact = path.join(checkout, "webviews/latency-results.json");
      if (missingBase) {
        expect(result.exitCode).not.toBe(0);
        expect(() => readFileSync(artifact)).toThrow();
      } else {
        expect(result.exitCode, result.stderr.toString()).toBe(0);
        expect(JSON.parse(readFileSync(artifact, "utf8"))).toEqual({ source: { head, base } });
        expect(base).not.toBe(head);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
