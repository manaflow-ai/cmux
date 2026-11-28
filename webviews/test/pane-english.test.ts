// The agent pane has no hard-coded English: every string a person reads comes from its table
// (acpmux/Localizable.xcstrings), so the pane follows the app's language. test/pane-english.ts
// finds rendered literals; a deliberate exception carries an `l10n-allow: <reason>` comment.
import { describe, expect, test } from "bun:test";
import { looksEnglish, scan } from "./pane-english";

describe("agent pane strings", () => {
  test("no user-visible English is written in the pane's sources", () => {
    const findings = scan().map((finding) => `${finding.file}:${finding.line} ${JSON.stringify(finding.text)}`);
    expect(findings).toEqual([]);
  });

  test("the scanner tells words a person reads from identifiers and symbols", () => {
    expect(looksEnglish("Copy path")).toBe(true);
    expect(looksEnglish("Thinking")).toBe(true);
    expect(looksEnglish("Copied.")).toBe(true);
    expect(looksEnglish("changes.copyPath")).toBe(false);
    expect(looksEnglish("acpmux-diff-tree")).toBe(false);
    expect(looksEnglish("{n}m")).toBe(false);
    expect(looksEnglish("⌘T")).toBe(false);
  });
});
