// The delineated diff (Leo 2026-10-20): the viewer reads code first and collapses what nobody
// wrote by hand, both from the one file-kind classifier (src/fileKinds.ts).
import { describe, expect, test } from "bun:test";
import { orderItemsByKind } from "../src/diff-kind-groups";
import { deferredDiffReason, isGeneratedDiffPath } from "../src/deferred-diffs";

const NONE: ReadonlySet<string> = new Set<string>();

function item(path: string, added = 0, deleted = 0) {
  return {
    id: path,
    fileDiff: { name: path, hunks: [{ additionLines: added, deletionLines: deleted }] },
  };
}

describe("orderItemsByKind", () => {
  test("code comes first and generated last, whatever order they streamed in", () => {
    const ordered = orderItemsByKind(
      [item("bun.lock"), item("webviews/test/a.test.ts"), item("README.md"), item("webviews/src/a.ts")],
      NONE,
    );
    expect(ordered.map((entry) => entry.id)).toEqual([
      "webviews/src/a.ts",
      "webviews/test/a.test.ts",
      "README.md",
      "bun.lock",
    ]);
  });

  test("files of one kind keep the order they came in", () => {
    const ordered = orderItemsByKind([item("src/z.ts"), item("src/a.ts"), item("src/m.ts")], NONE);
    expect(ordered.map((entry) => entry.id)).toEqual(["src/z.ts", "src/a.ts", "src/m.ts"]);
  });

  test("a change of one kind is handed back untouched, so the viewer re-renders nothing", () => {
    const items = [item("src/a.ts"), item("src/b.ts")];
    expect(orderItemsByKind(items, NONE)).toBe(items);
    expect(orderItemsByKind([], NONE)).toEqual([]);
  });

  test("the host's generated list moves a file to the end", () => {
    const items = [item("schemas/settings-schema.json"), item("src/a.ts")];
    expect(orderItemsByKind(items, NONE).map((entry) => entry.id)).toEqual([
      "schemas/settings-schema.json",
      "src/a.ts",
    ]);
    expect(orderItemsByKind(items, new Set(["schemas/settings-schema.json"])).map((entry) => entry.id)).toEqual([
      "src/a.ts",
      "schemas/settings-schema.json",
    ]);
  });
});

describe("generated files collapse", () => {
  test("the classifier decides, so tool output beyond the old lockfile list collapses too", () => {
    expect(isGeneratedDiffPath("bun.lock", NONE)).toBe(true);
    expect(isGeneratedDiffPath("webviews/src/agent-session/acpmux/Localizable.xcstrings", NONE)).toBe(true);
    expect(isGeneratedDiffPath("cmux.xcodeproj/project.pbxproj", NONE)).toBe(true);
    expect(isGeneratedDiffPath("web/public/vendor/highlight.min.js", NONE)).toBe(true);
    expect(isGeneratedDiffPath("webviews/src/App.tsx", NONE)).toBe(false);
    // A `Vendor/` folder is not enough: this repo keeps hand-written Swift under one, and
    // collapsing it behind "Load diff" hid 203 files a person does read. A vendored tree that
    // really is unread says so in .gitattributes, which arrives as the declared list.
    const vendored = "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/appkit-native/Compose.swift";
    expect(isGeneratedDiffPath(vendored, NONE)).toBe(false);
    expect(isGeneratedDiffPath(vendored, new Set([vendored]))).toBe(true);
  });

  test("a generated path is deferred before the size rules even look at it", () => {
    const small = { changedLines: 3, patchBytes: 100 };
    expect(deferredDiffReason({ path: "bun.lock", ...small, generatedPaths: NONE })).toBe("generated");
    expect(deferredDiffReason({ path: "ios/Localizable.xcstrings", ...small, generatedPaths: NONE })).toBe("generated");
    expect(deferredDiffReason({ path: "webviews/src/App.tsx", ...small, generatedPaths: NONE })).toBeUndefined();
    expect(
      deferredDiffReason({ path: "webviews/src/App.tsx", changedLines: 5_000, patchBytes: 100, generatedPaths: NONE }),
    ).toBe("large");
  });

  test("the host's declared list still wins for a path the shape rules miss", () => {
    expect(
      deferredDiffReason({
        path: "schemas/settings-schema.json",
        changedLines: 3,
        patchBytes: 100,
        generatedPaths: new Set(["schemas/settings-schema.json"]),
      }),
    ).toBe("generated");
  });
});
