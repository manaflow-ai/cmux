import { expect, test } from "bun:test";
import {
  firstFileLine,
  markdownFenceLanguages,
  resolveDiffFileLanguage,
  resolveDiffPreloadLanguages,
} from "../src/diff-language";
import { createDiffLanguageRegistry } from "../src/diff-languages/registry";

test("resolveDiffFileLanguage maps markdown extensions", () => {
  expect(resolveDiffFileLanguage("README.md")).toBe("markdown");
  expect(resolveDiffFileLanguage("docs/CHANGELOG.mdown")).toBe("markdown");
  expect(resolveDiffFileLanguage("notes/proposal.mkdn")).toBe("markdown");
});

test("resolveDiffFileLanguage fills common diff language gaps", () => {
  expect(resolveDiffFileLanguage("bun.lock")).toBe("jsonc");
  expect(resolveDiffFileLanguage("build.gradle")).toBe("groovy");
  expect(resolveDiffFileLanguage(".env.local")).toBe("dotenv");
  expect(resolveDiffFileLanguage("ios/Fastfile")).toBe("ruby");
});

test("resolveDiffFileLanguage keeps a non-text parsed language that can load", () => {
  expect(resolveDiffFileLanguage("README.md", "mdx")).toBe("mdx");
  expect(resolveDiffFileLanguage("src/App.tsx", "text")).toBe("tsx");
  expect(resolveDiffFileLanguage("src/App.tsx", "no-such-language")).toBe("tsx");
});

test("resolveDiffFileLanguage reads the shebang from line 1 of the diff", () => {
  const diff = {
    hunks: [{ additionStart: 1, additionLineIndex: 0, deletionStart: 1, deletionLineIndex: 0 }],
    additionLines: ["#!/usr/bin/env python3\n", "print(1)\n"],
    deletionLines: [],
  };
  expect(firstFileLine(diff)).toBe("#!/usr/bin/env python3");
  expect(resolveDiffFileLanguage("scripts/tool", undefined, diff)).toBe("python");
  // A hunk that starts later says nothing about line 1.
  const later = {
    ...diff,
    hunks: [{ additionStart: 40, additionLineIndex: 0, deletionStart: 40, deletionLineIndex: 0 }],
  };
  expect(resolveDiffFileLanguage("scripts/tool", undefined, later)).toBe("text");
});

test("resolveDiffFileLanguage uses the given registry", () => {
  const registry = createDiffLanguageRegistry();
  registry.install({ files: [{ path: "overrides.json", text: '{"extensions":{"md":"text"}}' }] });
  expect(resolveDiffFileLanguage("README.md", undefined, undefined, registry)).toBe("text");
  expect(resolveDiffFileLanguage("README.md")).toBe("markdown");
});

test("markdownFenceLanguages extracts supported fenced code languages", () => {
  expect(
    markdownFenceLanguages({
      additionLines: [
        "```swift\n",
        'let greeting = "hello"\n',
        "```\n",
        "~~~ts\n",
        "const ok = true\n",
        "~~~\n",
        "```zig\n",
        "```unknown\n",
      ],
    }),
  ).toEqual(["swift", "typescript", "zig"]);
});

test("resolveDiffPreloadLanguages includes Markdown embedded fence languages", () => {
  expect(
    resolveDiffPreloadLanguages("README.md", undefined, {
      additionLines: ["# Title\n", "```swift\n", 'print("hello")\n', "```\n"],
    }),
  ).toEqual(["markdown", "swift"]);
});

test("resolveDiffPreloadLanguages only extracts fences for Markdown-like files", () => {
  expect(
    resolveDiffPreloadLanguages("src/example.swift", "swift", {
      additionLines: ["```ts\n", "const ok = true\n"],
    }),
  ).toEqual(["swift"]);
});
