import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const workflow = readFileSync(new URL("../.github/workflows/nightly.yml", import.meta.url), "utf8");
const match = workflow.match(/          script: \|\n((?: {12}[^\n]*\n|\n)+)/);
assert.ok(match, "nightly decision script exists");
const script = match[1].replace(/^ {12}/gm, "");

async function decide({ files = [], status = "ahead", env = {}, branch = "main", missingTag = false, comparisonError = false } = {}) {
  const outputs = {};
  const summary = { addHeading() { return this; }, addTable() { return this; }, async write() {} };
  let comparisons = 0;
  await vm.runInNewContext(`(async () => {${script}\n})()`, {
    process: { env },
    context: { ref: `refs/heads/${branch}`, sha: "b".repeat(40), repo: { owner: "manaflow-ai", repo: "cmux" } },
    core: { setOutput(key, value) { outputs[key] = value; }, summary, warning() {}, info() {} },
    github: { rest: {
      git: { async getRef() {
        if (missingTag) throw { status: 404 };
        return { data: { object: { type: "commit", sha: "a".repeat(40) } } };
      } },
      repos: { async compareCommitsWithBasehead({ basehead }) {
        comparisons++;
        assert.equal(basehead, `${"a".repeat(40)}...${"b".repeat(40)}`);
        if (comparisonError) throw new Error("GitHub unavailable");
        return { data: { status, files } };
      } },
    } },
  });
  return { outputs, comparisons };
}

for (const path of ["web/app/page.tsx", "docs/ci-runners.md", "tests/test_example.py", "cmuxTests/Example.swift"]) {
  test(`does not rebuild the macOS app for ${path}`, async () => {
    assert.equal((await decide({ files: [{ filename: path }] })).outputs.should_build, "false");
  });
}

test("builds native, shared, bundled-client and unknown inputs", async () => {
  for (const path of ["Sources/App.swift", "Packages/iOS/CMUXMobileCore/Package.swift", "cmux-tui/src/main.rs", "Resources/icon.png", "new-build-input", ".github/workflows/nightly.yml"]) {
    assert.equal((await decide({ files: [{ filename: "web/app/page.tsx" }, { filename: path }] })).outputs.should_build, "true", path);
  }
});

test("a rename out of the native tree still rebuilds", async () => {
  const files = [{ filename: "docs/Old.swift", previous_filename: "Sources/Old.swift", status: "renamed" }];
  assert.equal((await decide({ files })).outputs.should_build, "true");
});

test("unavailable, truncated and non-ancestor comparisons build defensively", async () => {
  for (const scenario of [
    { comparisonError: true }, { missingTag: true }, { files: undefined, status: "diverged" },
    { files: Array.from({ length: 300 }, (_, i) => ({ filename: `web/${i}.ts` })) },
  ]) assert.equal((await decide(scenario)).outputs.should_build, "true");
});

test("explicit force, branch dogfood and measurement always build", async () => {
  for (const scenario of [{ env: { FORCE_BUILD: "true" } }, { branch: "feature" }, { env: { BUILD_ONLY: "true" } }]) {
    const { outputs, comparisons } = await decide(scenario);
    assert.equal(outputs.should_build, "true");
    assert.equal(comparisons, 0);
    if (scenario.env?.BUILD_ONLY) {
      assert.equal(outputs.should_publish, "false");
    }
  }
});
