// One classifier for the pull request card's by-kind breakdown and the diff viewer's grouped file
// list (Leo 2026-10-20). These are real cmux paths: when the two surfaces disagree about a file,
// they disagree here first.
import { describe, expect, test } from "bun:test";
import { fileKind, kindTotals, missingTests } from "../src/fileKinds";

describe("fileKind", () => {
  test("code is everything the change actually writes", () => {
    expect(fileKind("webviews/src/agent-session/acpmux/chips/LinkChips.tsx")).toBe("code");
    expect(fileKind("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPanePullRequest.swift")).toBe("code");
    expect(fileKind("cmux-tui/crates/cmux-tui-core/src/lib.rs")).toBe("code");
    expect(fileKind("scripts/cmux-next/prepush-gate.py")).toBe("code");
    expect(fileKind("package.json")).toBe("code");
  });

  test("a script that writes generated files is not a generated file", () => {
    expect(fileKind("scripts/cmux-next/gen-type-scale.py")).toBe("code");
    expect(fileKind("webviews/scripts/pages/gen-strings.mjs")).toBe("code");
  });

  test("tests are named tests, wherever they live", () => {
    expect(fileKind("webviews/test/pr-hover-card.test.tsx")).toBe("tests");
    expect(fileKind("webviews/src/agent-session/acpmux/chips/githubRef.test.ts")).toBe("tests");
    expect(
      fileKind("Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPanePullRequestInspectTests.swift"),
    ).toBe("tests");
    expect(fileKind("cmux-tui/crates/cmux-tui/tests/cases.rs")).toBe("tests");
    expect(fileKind("server/handler_test.go")).toBe("tests");
    expect(fileKind("tools/test_rulebook.py")).toBe("tests");
    expect(fileKind("webviews/bench/diff-stream.bench.ts")).toBe("tests");
  });

  test("a word that merely contains a kind's letters is still code", () => {
    expect(fileKind("web/app/latest.ts")).toBe("code");
    expect(fileKind("web/app/evaluate.ts")).toBe("code");
    expect(fileKind("web/app/contest.ts")).toBe("code");
    expect(fileKind("web/app/oxygen.ts")).toBe("code");
    expect(fileKind("web/app/Protest.swift")).toBe("code");
  });

  test("mocks and fixtures are scaffolding, not tests", () => {
    expect(fileKind("webviews/src/agent-session/acpmux/mock.ts")).toBe("mocks");
    expect(fileKind("webviews/src/agent-session/acpmux/mockFixture.ts")).toBe("mocks");
    expect(fileKind("Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Mock/MockHomeSource.swift")).toBe("mocks");
    expect(fileKind("cmux-tui/crates/cmux-palette-ranker/tests/corpus/fixtures/palette.json")).toBe("mocks");
    expect(fileKind("web/__mocks__/stripe.ts")).toBe("mocks");
    expect(fileKind("server/testdata/reply.json")).toBe("mocks");
  });

  test("a test file named after its fixtures is a test", () => {
    expect(fileKind("webviews/test/agent-pane-fixtures.test.ts")).toBe("tests");
    expect(fileKind("webviews/test/mock-host.spec.ts")).toBe("tests");
  });

  test("evals read as their own work", () => {
    expect(fileKind("evals/tone/answers.json")).toBe("evals");
    expect(fileKind("web/prompts/tone.eval.ts")).toBe("evals");
    expect(fileKind("web/prompts/ToneEvals.ts")).toBe("evals");
  });

  test("docs are prose, named documents and anything under docs/", () => {
    expect(fileKind("CLAUDE.md")).toBe("docs");
    expect(fileKind("docs/ci/merge-main.md")).toBe("docs");
    expect(fileKind("LICENSE")).toBe("docs");
    expect(fileKind("docs/mdm/profile.plist")).toBe("docs");
    expect(fileKind("skills/cmux-review/SKILL.md")).toBe("docs");
  });

  test("a document's whole name is a document; code that serves documents is code", () => {
    // The name, never the stem: these three are the code behind a changelog page, a security
    // service and the changes list, and calling them Docs hid them from the "no tests" warning
    // and sorted them away from the code they belong to.
    expect(fileKind("web/app/lib/changelog.ts")).toBe("code");
    expect(fileKind("web/services/vm-publications/security.ts")).toBe("code");
    expect(fileKind("webviews/src/agent-session/acpmux/changes/changes.css")).toBe("code");
    expect(fileKind("CHANGELOG")).toBe("docs");
    expect(fileKind("CHANGELOG.md")).toBe("docs");
    expect(fileKind("SECURITY.md")).toBe("docs");
  });

  test("a spec folder holds a protocol as often as a test, so only the name makes a test", () => {
    expect(fileKind("cmux-tui/spec/api-compat.json")).toBe("code");
    expect(fileKind("cmux-tui/crates/acpmux/spec/acpmux-protocol.json")).toBe("code");
    // A spec file that is a test still says so in its name.
    expect(fileKind("cmux-tui/crates/cmux-theme-tokens/src/spec/tests.rs")).toBe("tests");
    expect(fileKind("webviews/test/router.spec.ts")).toBe("tests");
  });

  test("generated files are lockfiles, tool output and translation catalogs", () => {
    expect(fileKind("bun.lock")).toBe("generated");
    expect(fileKind("Cargo.lock")).toBe("generated");
    expect(fileKind("Packages/macOS/CmuxNext/Package.resolved")).toBe("generated");
    expect(fileKind("webviews/src/diff/generated/protocol.ts")).toBe("generated");
    expect(fileKind("webviews/src/protocol/pane.generated.ts")).toBe("generated");
    expect(fileKind("cmux.xcodeproj/project.pbxproj")).toBe("generated");
    expect(fileKind("webviews/src/agent-session/acpmux/Localizable.xcstrings")).toBe("generated");
    expect(fileKind("web/public/vendor/highlight.min.js")).toBe("generated");
  });

  test("prose about generated files is prose: a document's name says what it is about", () => {
    // The four of these in this repo are hand-written: each says which script writes that
    // directory's bundle, and a reader opens them. A generated document says so in its suffix,
    // or sits in a generated tree.
    expect(fileKind("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/GENERATED.md")).toBe(
      "docs",
    );
    expect(fileKind("docs/generated.md")).toBe("docs");
    expect(fileKind("docs/api.generated.md")).toBe("generated");
    expect(fileKind("webviews/src/icon-picker/generated/LICENSES.md")).toBe("generated");
  });

  test("a vendor folder is not generated: this repo keeps hand-written Swift under one", () => {
    expect(fileKind("Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Compose.swift")).toBe(
      "code",
    );
    expect(fileKind("web/vendor/stripe-client.ts")).toBe("code");
  });

  test("the host's generated list wins over the path's own shape", () => {
    const declared = new Set(["schemas/settings-schema.json"]);
    expect(fileKind("schemas/settings-schema.json")).toBe("code");
    expect(fileKind("schemas/settings-schema.json", declared)).toBe("generated");
    expect(fileKind("webviews/src/App.tsx", declared)).toBe("code");
  });
});

describe("kindTotals", () => {
  test("adds the lines up per kind, in the order every surface lists them", () => {
    const totals = kindTotals([
      { path: "webviews/src/a.ts", additions: 10, deletions: 2 },
      { path: "webviews/src/b.ts", additions: 5, deletions: 0 },
      { path: "webviews/test/a.test.ts", additions: 40, deletions: 1 },
      { path: "bun.lock", additions: 1200, deletions: 3 },
      { path: "README.md", additions: 4, deletions: 4 },
    ]);
    expect(totals).toEqual([
      { kind: "code", files: 2, additions: 15, deletions: 2 },
      { kind: "tests", files: 1, additions: 40, deletions: 1 },
      { kind: "docs", files: 1, additions: 4, deletions: 4 },
      { kind: "generated", files: 1, additions: 1200, deletions: 3 },
    ]);
  });

  test("a file with no counts still counts as a file", () => {
    expect(kindTotals([{ path: "web/app/page.tsx" }])).toEqual([
      { kind: "code", files: 1, additions: 0, deletions: 0 },
    ]);
  });

  test("nothing changed, nothing listed", () => {
    expect(kindTotals([])).toEqual([]);
  });
});

describe("missingTests", () => {
  test("warns when the change writes code and no test", () => {
    expect(missingTests([{ path: "webviews/src/a.ts" }])).toBe(true);
    expect(missingTests([{ path: "webviews/src/a.ts" }, { path: "webviews/test/a.test.ts" }])).toBe(false);
  });

  test("a change with no code of its own is not missing a test", () => {
    expect(missingTests([{ path: "README.md" }, { path: "bun.lock" }])).toBe(false);
    expect(missingTests([])).toBe(false);
  });

  test("mocks and docs beside code do not stand in for a test", () => {
    expect(missingTests([{ path: "webviews/src/a.ts" }, { path: "webviews/src/mock.ts" }, { path: "docs/a.md" }])).toBe(
      true,
    );
  });
});
