import { afterEach, beforeEach, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
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
let shallowClone: string | undefined;

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
  root: string = repository,
): number | null {
  const result = spawnSync("bash", [ignoreBuildScript], {
    cwd: join(root, "web"),
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
  mkdirSync(join(repository, "web", "app"), { recursive: true });
  mkdirSync(join(repository, "web", "tools"), { recursive: true });
  mkdirSync(join(repository, "config", "iroh"), { recursive: true });
  mkdirSync(join(repository, "workers", "presence", "src", "generated"), {
    recursive: true,
  });
  mkdirSync(join(repository, "Sources"), { recursive: true });
  writeFileSync(
    join(repository, "web", "app", "page.tsx"),
    "export default null;\n",
  );
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
  // Also on a failing assertion: a leaked shallow clone is ~130 MB, and a few
  // reruns of a red test would fill a runner's tmpfs.
  if (shallowClone && existsSync(shallowClone)) {
    rmSync(shallowClone, { recursive: true, force: true });
  }
  shallowClone = undefined;
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
    join(repository, "web", "app", "page.tsx"),
    "export default function Page() {}\n",
  );
  const webChange = commit("web change");
  expect(ignoreBuild(base, webChange)).toBe(1);

  rmSync(join(repository, "web", "app", "page.tsx"));
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
}, 15000);

test("skips changes that cannot affect the deployed web output", () => {
  const base = commit("base");

  mkdirSync(join(repository, "web", "tests"), { recursive: true });
  writeFileSync(join(repository, "web", "tests", "example.test.ts"), "test();\n");
  const testChange = commit("test change");
  expect(ignoreBuild(base, testChange)).toBe(0);

  writeFileSync(join(repository, "web", "tools", "build-docs-search.mjs"), "console.log('changed');\n");
  const buildToolChange = commit("build tool change");
  expect(ignoreBuild(testChange, buildToolChange)).toBe(1);
});

test("builds for new production directories and docs deployment configuration", () => {
  let previous = commit("base");
  for (const file of ["lib/new-runtime.ts", "vercel.docs-channel.json", "pagefind.yml"]) {
    const destination = join(repository, "web", file);
    mkdirSync(join(destination, ".."), { recursive: true });
    writeFileSync(destination, "changed\n");
    const current = commit(`add ${file}`);
    expect(ignoreBuild(previous, current)).toBe(1);
    previous = current;
  }
});

test("skips local scripts but builds when a commit also changes production files", () => {
  const base = commit("base");
  mkdirSync(join(repository, "web", "scripts"), { recursive: true });
  writeFileSync(join(repository, "web", "scripts", "dev-local.sh"), "echo local\n");
  const localChange = commit("local script change");
  expect(ignoreBuild(base, localChange)).toBe(0);

  writeFileSync(join(repository, "web", "app", "page.tsx"), "export default 1;\n");
  const mixedChange = commit("production change");
  expect(ignoreBuild(base, mixedChange)).toBe(1);
  expect(ignoreBuild(mixedChange, "missing-current-sha")).toBe(1);
});

test("recovers the previous deployment from outside a shallow clone", () => {
  // Vercel clones shallowly. main lands commits faster than that clone is
  // deep, so the previously deployed commit is normally missing from it.
  const deployed = commit("deployed");
  for (let index = 0; index < 5; index += 1) {
    writeFileSync(join(repository, "Sources", "App.swift"), `let app = ${index}\n`);
    commit(`native change ${index}`);
  }
  const head = git("rev-parse", "HEAD");

  const shallow = mkdtempSync(join(tmpdir(), "cmux-vercel-shallow-"));
  shallowClone = shallow;
  rmSync(shallow, { recursive: true, force: true });
  execFileSync("git", [
    "clone", "--depth", "1", "--branch", git("rev-parse", "--abbrev-ref", "HEAD"),
    `file://${repository}`, shallow,
  ]);
  expect(
    spawnSync("git", ["cat-file", "-e", `${deployed}^{commit}`], { cwd: shallow })
      .status,
  ).not.toBe(0);

  // Nothing under web/ changed, so the build must be skipped even though the
  // marker is outside the clone. Before the fetch, this returned 1.
  expect(ignoreBuild(deployed, head, shallow)).toBe(0);
}, 30000);

test("still builds when the previous deployment cannot be fetched at all", () => {
  const base = commit("base");
  const shallow = mkdtempSync(join(tmpdir(), "cmux-vercel-unreachable-"));
  shallowClone = shallow;
  rmSync(shallow, { recursive: true, force: true });
  execFileSync("git", [
    "clone", "--depth", "1", "--branch", git("rev-parse", "--abbrev-ref", "HEAD"),
    `file://${repository}`, shallow,
  ]);

  // A commit no remote has: the fetch fails and the build still runs.
  expect(ignoreBuild("0".repeat(40), base, shallow)).toBe(1);
  expect(ignoreBuild(undefined, base, shallow)).toBe(1);
}, 30000);

test("the deployment exclusions keep the history this script reads", () => {
  // Every decision here comes from Git. If .vercelignore excludes .git, and
  // Vercel applies it before the ignored-build command, nothing can be
  // compared and every push builds. Assert with the repository's real rules.
  // Copy before the baseline: .vercelignore is itself a build input, so
  // changing it inside the compared range would correctly force a build.
  copyFileSync(
    fileURLToPath(new URL("../../.vercelignore", import.meta.url)),
    join(repository, ".vercelignore"),
  );
  const base = commit("base");
  const excluded = spawnSync(
    "git",
    ["-c", "core.excludesFile=.vercelignore", "check-ignore", "--no-index", ".git/HEAD"],
    { cwd: repository },
  );
  expect(excluded.status).not.toBe(0);

  writeFileSync(join(repository, "Sources", "App.swift"), "let app = false\n");
  expect(ignoreBuild(base, commit("native change"))).toBe(0);
});
