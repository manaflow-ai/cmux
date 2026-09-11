import { afterEach, beforeEach, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ignoreBuildScript = fileURLToPath(
  new URL("../tools/vercel-ignore-build.sh", import.meta.url),
);
let repository: string;

function git(...args: string[]): string {
  return execFileSync("git", args, {
    cwd: repository,
    encoding: "utf8",
  }).trim();
}

function commit(message: string): string {
  git("add", ".");
  git(
    "-c",
    "user.name=Vercel test",
    "-c",
    "user.email=test@example.com",
    "commit",
    "-m",
    message,
  );
  return git("rev-parse", "HEAD");
}

function ignoreBuild(
  previous: string | undefined,
  current: string,
): number | null {
  const result = spawnSync("bash", [ignoreBuildScript], {
    cwd: join(repository, "web"),
    encoding: "utf8",
    env: {
      ...process.env,
      VERCEL_GIT_PREVIOUS_SHA: previous ?? "",
      VERCEL_GIT_COMMIT_SHA: current,
    },
  });
  return result.status;
}

beforeEach(() => {
  repository = mkdtempSync(join(tmpdir(), "cmux-vercel-ignore-"));
  mkdirSync(join(repository, "web", "tools"), { recursive: true });
  mkdirSync(join(repository, "config", "iroh"), { recursive: true });
  mkdirSync(join(repository, "workers", "presence", "src", "generated"), {
    recursive: true,
  });
  mkdirSync(join(repository, "Sources"), { recursive: true });
  writeFileSync(join(repository, "web", "page.tsx"), "export default null;\n");
  writeFileSync(join(repository, ".vercelignore"), "node_modules/\n");
  writeFileSync(join(repository, "CHANGELOG.md"), "## [1.0.0] - 2026-01-01\n");
  writeFileSync(
    join(repository, "config", "iroh", "managed-relay-catalog.json"),
    "{}\n",
  );
  writeFileSync(
    join(repository, "workers", "presence", "src", "generated", "managedRelayCatalog.ts"),
    "export {};\n",
  );
  writeFileSync(join(repository, "Sources", "App.swift"), "let app = true\n");
  git("init", "-q");
  git("config", "user.name", "Vercel test");
  git("config", "user.email", "test@example.com");
});

afterEach(() => {
  if (repository && existsSync(repository)) {
    rmSync(repository, { recursive: true, force: true });
  }
});

test("skips commits that do not change web build inputs", () => {
  const base = commit("base");

  expect(ignoreBuild(undefined, base)).toBe(1);
  expect(ignoreBuild(base, base)).toBe(0);

  writeFileSync(join(repository, "Sources", "App.swift"), "let app = false\n");
  const nativeChange = commit("native change");
  expect(ignoreBuild(base, nativeChange)).toBe(0);
});

test("builds when a web or shared build input changes", () => {
  const base = commit("base");

  writeFileSync(
    join(repository, "web", "page.tsx"),
    "export default function Page() {}\n",
  );
  const webChange = commit("web change");
  expect(ignoreBuild(base, webChange)).toBe(1);

  rmSync(join(repository, "web", "page.tsx"));
  const webDeletion = commit("web deletion");
  expect(ignoreBuild(webChange, webDeletion)).toBe(1);

  writeFileSync(join(repository, "CHANGELOG.md"), "## [1.0.1] - 2026-01-02\n");
  const changelogChange = commit("changelog change");
  expect(ignoreBuild(webDeletion, changelogChange)).toBe(1);

  writeFileSync(join(repository, ".vercelignore"), "node_modules/\nbuild/\n");
  const vercelIgnoreChange = commit("Vercel ignore change");
  expect(ignoreBuild(changelogChange, vercelIgnoreChange)).toBe(1);

  writeFileSync(
    join(repository, "config", "iroh", "managed-relay-catalog.json"),
    '{"sequence":2}\n',
  );
  const configChange = commit("relay config change");
  expect(ignoreBuild(vercelIgnoreChange, configChange)).toBe(1);

  writeFileSync(
    join(
      repository,
      "workers",
      "presence",
      "src",
      "generated",
      "managedRelayCatalog.ts",
    ),
    "export const sequence = 2;\n",
  );
  const generatedChange = commit("generated relay change");
  expect(ignoreBuild(configChange, generatedChange)).toBe(1);
  expect(ignoreBuild("missing-sha", generatedChange)).toBe(1);
});
