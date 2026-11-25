import { afterEach, beforeEach, expect, test } from "bun:test";
import { runChild, runChildOk } from "./helpers/run-child";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
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
const extraDirectories: string[] = [];

/** Runs git in the fixture repository and returns trimmed stdout; throws on failure. */
async function git(...args: string[]): Promise<string> {
  const result = await runChildOk("git", args, {
    cwd: repository,
  });
  return result.stdout.trim();
}

/** Commits every change in the fixture repository and returns the new HEAD. */
async function commit(message: string): Promise<string> {
  await git("add", ".");
  await git(
    "-c",
    "user.name=Vercel test",
    "-c",
    "user.email=test@example.com",
    "commit",
    "-m",
    message,
  );
  return await git("rev-parse", "HEAD");
}

/** Runs the Vercel ignore-build script for a commit range and returns its exit status. */
async function ignoreBuild(
  previous: string | undefined,
  current: string,
  root: string = repository,
  env: Record<string, string> = {},
): Promise<number | null> {
  const result = await runChild("bash", [ignoreBuildScript], {
    cwd: join(root, "web"),
    env: {
      ...process.env,
      // Never reach the real GitHub from a test: by default the public remote
      // and the compare API both fail at once, as no network would.
      CMUX_VERCEL_IGNORE_PUBLIC_REMOTE: unreachableRemote,
      CMUX_VERCEL_IGNORE_GITHUB_API: "http://127.0.0.1:9",
      GITHUB_TOKEN: "",
      ...env,
      VERCEL_GIT_PREVIOUS_SHA: previous ?? "",
      VERCEL_GIT_COMMIT_SHA: current,
    },
  });
  return result.status;
}

const unreachableRemote = `file://${join(tmpdir(), "cmux-vercel-ignore-no-such-remote")}`;
/** Vercel's build clone is this many commits deep. */
const vercelCloneDepth = 10;

beforeEach(async () => {
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
  await git("init", "-q");
  await git("config", "user.name", "Vercel test");
  await git("config", "user.email", "test@example.com");
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
  for (const directory of extraDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("skips commits that do not change web build inputs", async () => {
  const base = await commit("base");

  expect(await ignoreBuild(undefined, base)).toBe(1);
  expect(await ignoreBuild(base, base)).toBe(0);

  writeFileSync(join(repository, "Sources", "App.swift"), "let app = false\n");
  const nativeChange = await commit("native change");
  expect(await ignoreBuild(base, nativeChange)).toBe(0);
});

test("builds when a web or shared build input changes", async () => {
  const base = await commit("base");

  writeFileSync(
    join(repository, "web", "app", "page.tsx"),
    "export default function Page() {}\n",
  );
  const webChange = await commit("web change");
  expect(await ignoreBuild(base, webChange)).toBe(1);

  rmSync(join(repository, "web", "app", "page.tsx"));
  const webDeletion = await commit("web deletion");
  expect(await ignoreBuild(webChange, webDeletion)).toBe(1);

  writeFileSync(join(repository, "CHANGELOG.md"), "## [1.0.1] - 2026-01-02\n");
  const changelogChange = await commit("changelog change");
  expect(await ignoreBuild(webDeletion, changelogChange)).toBe(1);

  writeFileSync(join(repository, ".vercelignore"), "node_modules/\nbuild/\n");
  const vercelIgnoreChange = await commit("Vercel ignore change");
  expect(await ignoreBuild(changelogChange, vercelIgnoreChange)).toBe(1);

  writeFileSync(
    join(repository, "config", "iroh", "managed-relay-catalog.json"),
    '{"sequence":2}\n',
  );
  const configChange = await commit("relay config change");
  expect(await ignoreBuild(vercelIgnoreChange, configChange)).toBe(1);

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
  const generatedChange = await commit("generated relay change");
  expect(await ignoreBuild(configChange, generatedChange)).toBe(1);
  expect(await ignoreBuild("missing-sha", generatedChange)).toBe(1);
}, 15000);

test("skips changes that cannot affect the deployed web output", async () => {
  const base = await commit("base");

  mkdirSync(join(repository, "web", "tests"), { recursive: true });
  writeFileSync(join(repository, "web", "tests", "example.test.ts"), "test();\n");
  const testChange = await commit("test change");
  expect(await ignoreBuild(base, testChange)).toBe(0);

  writeFileSync(join(repository, "web", "tools", "build-docs-search.mjs"), "console.log('changed');\n");
  const buildToolChange = await commit("build tool change");
  expect(await ignoreBuild(testChange, buildToolChange)).toBe(1);
});

test("builds for new production directories and docs deployment configuration", async () => {
  let previous = await commit("base");
  for (const file of ["lib/new-runtime.ts", "vercel.docs-channel.json", "pagefind.yml"]) {
    const destination = join(repository, "web", file);
    mkdirSync(join(destination, ".."), { recursive: true });
    writeFileSync(destination, "changed\n");
    const current = await commit(`add ${file}`);
    expect(await ignoreBuild(previous, current)).toBe(1);
    previous = current;
  }
});

test("skips local scripts but builds when a commit also changes production files", async () => {
  const base = await commit("base");
  mkdirSync(join(repository, "web", "scripts"), { recursive: true });
  writeFileSync(join(repository, "web", "scripts", "dev-local.sh"), "echo local\n");
  const localChange = await commit("local script change");
  expect(await ignoreBuild(base, localChange)).toBe(0);

  writeFileSync(join(repository, "web", "app", "page.tsx"), "export default 1;\n");
  const mixedChange = await commit("production change");
  expect(await ignoreBuild(base, mixedChange)).toBe(1);
  expect(await ignoreBuild(mixedChange, "missing-current-sha")).toBe(1);
});

test("recovers the previous deployment from outside a shallow clone", async () => {
  // Vercel clones shallowly. main lands commits faster than that clone is
  // deep, so the previously deployed commit is normally missing from it.
  const deployed = await commit("deployed");
  for (let index = 0; index < 5; index += 1) {
    writeFileSync(join(repository, "Sources", "App.swift"), `let app = ${index}\n`);
    await commit(`native change ${index}`);
  }
  const head = await git("rev-parse", "HEAD");

  const shallow = mkdtempSync(join(tmpdir(), "cmux-vercel-shallow-"));
  shallowClone = shallow;
  rmSync(shallow, { recursive: true, force: true });
  await runChildOk("git", [
    "clone", "--depth", "1", "--branch", await git("rev-parse", "--abbrev-ref", "HEAD"),
    `file://${repository}`, shallow,
  ]);
  const deployedLookup = await runChild("git", ["cat-file", "-e", `${deployed}^{commit}`], { cwd: shallow });
  expect(deployedLookup.signal).toBeNull();
  expect(deployedLookup.status).not.toBe(0);

  // Nothing under web/ changed, so the build must be skipped even though the
  // marker is outside the clone. Before the fetch, this returned 1.
  expect(await ignoreBuild(deployed, head, shallow)).toBe(0);
}, 30000);

test("still builds when the previous deployment cannot be fetched at all", async () => {
  const base = await commit("base");
  const shallow = mkdtempSync(join(tmpdir(), "cmux-vercel-unreachable-"));
  shallowClone = shallow;
  rmSync(shallow, { recursive: true, force: true });
  await runChildOk("git", [
    "clone", "--depth", "1", "--branch", await git("rev-parse", "--abbrev-ref", "HEAD"),
    `file://${repository}`, shallow,
  ]);

  // A commit no remote has: the fetch fails and the build still runs.
  expect(await ignoreBuild("0".repeat(40), base, shallow)).toBe(1);
  expect(await ignoreBuild(undefined, base, shallow)).toBe(1);
}, 30000);

test("the deployment exclusions keep the history this script reads", async () => {
  // Every decision here comes from Git. If .vercelignore excludes .git, and
  // Vercel applies it before the ignored-build command, nothing can be
  // compared and every push builds. Assert with the repository's real rules.
  // Copy before the baseline: .vercelignore is itself a build input, so
  // changing it inside the compared range would correctly force a build.
  copyFileSync(
    fileURLToPath(new URL("../../.vercelignore", import.meta.url)),
    join(repository, ".vercelignore"),
  );
  const base = await commit("base");
  const excluded = await runChild(
    "git",
    ["-c", "core.excludesFile=.vercelignore", "check-ignore", "--no-index", ".git/HEAD"],
    { cwd: repository },
  );
  expect(excluded.signal).toBeNull();
  expect(excluded.status).not.toBe(0);

  writeFileSync(join(repository, "Sources", "App.swift"), "let app = false\n");
  expect(await ignoreBuild(base, await commit("native change"))).toBe(0);
});

test("fetches the previous deployment from the public remote when origin refuses", async () => {
  const deployed = await commit("deployed");
  for (let index = 0; index < vercelCloneDepth + 2; index += 1) {
    writeFileSync(join(repository, "Sources", "App.swift"), `let app = ${index}\n`);
    await commit(`native change ${index}`);
  }
  const head = await git("rev-parse", "HEAD");
  const shallow = await vercelClone(repository);
  // What 2026-11-15..22 looked like on Vercel: origin could not serve the
  // previous commit, so every 10th commit since a build built again.
  await runChildOk("git", ["remote", "set-url", "origin", unreachableRemote], { cwd: shallow });

  expect(await ignoreBuild(deployed, head, shallow)).toBe(1);
  expect(
    await ignoreBuild(deployed, head, shallow, {
      CMUX_VERCEL_IGNORE_PUBLIC_REMOTE: `file://${repository}`,
    }),
  ).toBe(0);

  // A clone with no origin at all goes straight to the public remote.
  const noOrigin = await vercelClone(repository);
  await runChildOk("git", ["remote", "remove", "origin"], { cwd: noOrigin });
  expect(
    await ignoreBuild(deployed, head, noOrigin, {
      CMUX_VERCEL_IGNORE_PUBLIC_REMOTE: `file://${repository}`,
    }),
  ).toBe(0);
}, 60000);

interface ReplayCase {
  previous: string;
  current: string;
  commits: number;
  webBuildInputsChanged: boolean;
  changedPaths: string[];
}

const replay = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("./fixtures/vercel-ignore-replay.json", import.meta.url)),
    "utf8",
  ),
) as { cases: ReplayCase[] };

test("the replay holds every kind of production deploy it is meant to judge", () => {
  const skips = replay.cases.filter((replayCase) => !replayCase.webBuildInputsChanged);
  const builds = replay.cases.filter((replayCase) => replayCase.webBuildInputsChanged);
  expect(skips.length).toBeGreaterThanOrEqual(13);
  expect(builds.length).toBeGreaterThanOrEqual(5);
  expect(skips.filter((replayCase) => replayCase.commits >= vercelCloneDepth).length).toBeGreaterThanOrEqual(11);
  expect(builds.filter((replayCase) => replayCase.commits >= vercelCloneDepth).length).toBeGreaterThanOrEqual(4);
});

for (const replayCase of replay.cases) {
  const range = `${replayCase.previous.slice(0, 10)}..${replayCase.current.slice(0, 10)}`;
  const verdict = replayCase.webBuildInputsChanged ? "builds" : "skips";
  test(`replay ${range} (${replayCase.commits} commits) ${verdict} from a 10-deep clone`, async () => {
    // Rebuild the range: one commit holding every path it touched, as many
    // commits after it as the real range had, the last one changing every
    // path. The answer only depends on which paths changed.
    mkdirSync(join(repository, "web"), { recursive: true });
    writeFileSync(join(repository, "replay-filler.txt"), "0\n");
    for (const path of replayCase.changedPaths) {
      mkdirSync(join(repository, path, ".."), { recursive: true });
      writeFileSync(join(repository, path), "before\n");
    }
    const deployed = await commit("deployed");
    for (let index = 1; index < replayCase.commits; index += 1) {
      writeFileSync(join(repository, "replay-filler.txt"), `${index}\n`);
      await commit(`between ${index}`);
    }
    for (const path of replayCase.changedPaths) {
      writeFileSync(join(repository, path), "after\n");
    }
    const built = await commit("built");
    expect(Number(await git("rev-list", "--count", `${deployed}..${built}`))).toBe(replayCase.commits);

    // A fresh clone for each source: a fetch leaves the commit behind, and the
    // next source would never be asked.
    const brokenOriginClone = async (): Promise<string> => {
      const clone = await vercelClone(repository);
      await runChildOk("git", ["remote", "set-url", "origin", unreachableRemote], { cwd: clone });
      const lookup = await runChild("git", ["cat-file", "-e", `${deployed}^{commit}`], { cwd: clone });
      expect(lookup.status === 0).toBe(replayCase.commits < vercelCloneDepth);
      return clone;
    };

    const expected = replayCase.webBuildInputsChanged ? 1 : 0;
    // From the public remote.
    expect(
      await ignoreBuild(deployed, built, await brokenOriginClone(), {
        CMUX_VERCEL_IGNORE_PUBLIC_REMOTE: `file://${repository}`,
      }),
    ).toBe(expected);

    if (replayCase.commits < vercelCloneDepth) return;
    // From GitHub's compare API, when no remote can serve the commit.
    const bin = fakeCurl(
      JSON.stringify({
        status: "ahead",
        files: replayCase.changedPaths.map((filename) => ({ filename, status: "modified" })),
      }),
    );
    expect(
      await ignoreBuild(deployed, built, await brokenOriginClone(), {
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        CMUX_VERCEL_IGNORE_GITHUB_API: "https://api.github.invalid",
      }),
    ).toBe(expected);
    // And with every source down, it still builds.
    expect(await ignoreBuild(deployed, built, await brokenOriginClone())).toBe(1);
  }, 60000);
}

test("the compare API answer is used only when complete and linear", async () => {
  const deployed = await commit("deployed");
  for (let index = 0; index < vercelCloneDepth + 1; index += 1) {
    writeFileSync(join(repository, "Sources", "App.swift"), `let app = ${index}\n`);
    await commit(`native change ${index}`);
  }
  const head = await git("rev-parse", "HEAD");
  const shallow = await vercelClone(repository);
  await runChildOk("git", ["remote", "set-url", "origin", unreachableRemote], { cwd: shallow });

  const answers: Array<[unknown, number]> = [
    [{ status: "ahead", files: [{ filename: "Sources/App.swift" }] }, 0],
    [{ status: "identical", files: [] }, 0],
    [{ status: "ahead", files: [{ filename: "web/tests/a.test.ts" }, { filename: "web/README.md" }] }, 0],
    [{ status: "ahead", files: [{ filename: "web/app/page.tsx" }] }, 1],
    [{ status: "ahead", files: [{ filename: "CHANGELOG.md" }] }, 1],
    [{ status: "ahead", files: [{ filename: "web/lib/x.ts", previous_filename: "web/tests/x.ts" }] }, 1],
    [{ status: "ahead", files: [{ filename: "Sources/x.swift", previous_filename: "web/app/x.ts" }] }, 1],
    [{ status: "diverged", files: [] }, 1],
    [{ status: "ahead", files: Array.from({ length: 300 }, (_, index) => ({ filename: `Sources/${index}` })) }, 1],
    ["not json", 1],
  ];
  for (const [answer, expected] of answers) {
    const bin = fakeCurl(typeof answer === "string" ? answer : JSON.stringify(answer));
    expect(
      await ignoreBuild(deployed, head, shallow, {
        PATH: `${bin}:${process.env.PATH ?? ""}`,
        CMUX_VERCEL_IGNORE_GITHUB_API: "https://api.github.invalid",
      }),
    ).toBe(expected);
  }
}, 60000);

/** Clones `source` the way Vercel does (10 commits deep) into a directory afterEach removes. */
async function vercelClone(source: string): Promise<string> {
  const clone = mkdtempSync(join(tmpdir(), "cmux-vercel-clone-"));
  extraDirectories.push(clone);
  rmSync(clone, { recursive: true, force: true });
  const branch = (
    await runChildOk("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: source })
  ).stdout.trim();
  await runChildOk("git", [
    "clone", "--quiet", "--depth", String(vercelCloneDepth), "--branch", branch,
    `file://${source}`, clone,
  ]);
  return clone;
}

/** A directory whose `curl` prints `body`, standing in for GitHub's compare API. */
function fakeCurl(body: string): string {
  const bin = mkdtempSync(join(tmpdir(), "cmux-vercel-curl-"));
  extraDirectories.push(bin);
  writeFileSync(join(bin, "response.json"), body);
  writeFileSync(join(bin, "curl"), `#!/bin/sh\ncat '${join(bin, "response.json")}'\n`, { mode: 0o755 });
  return bin;
}
