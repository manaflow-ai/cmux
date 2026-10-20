import { expect, test } from "bun:test";
import { markdownFenceLanguages, resolveDiffFileLanguage, resolveDiffPreloadLanguages } from "../src/diff-language";

test("resolveDiffFileLanguage maps markdown extensions even when fallback is plain text", () => {
  const fallback = () => "text";

  expect(resolveDiffFileLanguage("README.md", undefined, fallback)).toBe("markdown");
  expect(resolveDiffFileLanguage("docs/CHANGELOG.mdown", undefined, fallback)).toBe("markdown");
  expect(resolveDiffFileLanguage("notes/proposal.mkdn", undefined, fallback)).toBe("markdown");
});

test("resolveDiffFileLanguage fills common diff language gaps", () => {
  const fallback = () => "text";

  expect(resolveDiffFileLanguage("bun.lock", undefined, fallback)).toBe("toml");
  expect(resolveDiffFileLanguage("build.gradle", undefined, fallback)).toBe("groovy");
  expect(resolveDiffFileLanguage(".env.local", undefined, fallback)).toBe("dotenv");
  expect(resolveDiffFileLanguage("ios/Fastfile", undefined, fallback)).toBe("ruby");
});

test("resolveDiffFileLanguage keeps non-text parsed and fallback languages", () => {
  expect(resolveDiffFileLanguage("README.md", "mdx", () => "text")).toBe("mdx");
  expect(resolveDiffFileLanguage("src/App.tsx", undefined, () => "tsx")).toBe("tsx");
});

test("markdownFenceLanguages extracts supported fenced code languages", () => {
  expect(markdownFenceLanguages({
    additionLines: [
      "```swift\n",
      "let greeting = \"hello\"\n",
      "```\n",
      "~~~ts\n",
      "const ok = true\n",
      "~~~\n",
      "```unknown\n",
    ],
  })).toEqual(["swift", "typescript"]);
});

test("resolveDiffPreloadLanguages includes Markdown embedded fence languages", () => {
  expect(resolveDiffPreloadLanguages("README.md", undefined, {
    additionLines: [
      "# Title\n",
      "```swift\n",
      "print(\"hello\")\n",
      "```\n",
    ],
  }, () => "text")).toEqual(["markdown", "swift"]);
});

test("resolveDiffPreloadLanguages only extracts fences for Markdown-like files", () => {
  expect(resolveDiffPreloadLanguages("src/example.swift", "swift", {
    additionLines: [
      "```ts\n",
      "const ok = true\n",
    ],
  })).toEqual(["swift"]);
});
