// The agent pane has no hard-coded English: every string a person reads comes from its table
// (acpmux/Localizable.xcstrings), so the pane follows the app's language. test/pane-english.ts
// finds rendered literals; a deliberate exception carries an `l10n-allow: <reason>` comment.
import { describe, expect, test } from "bun:test";
import { scan } from "./pane-english";

describe("agent pane strings", () => {
  test("no user-visible English is written in the pane's sources", () => {
    const findings = scan().map((finding) => `${finding.file}:${finding.line} ${JSON.stringify(finding.text)}`);
    expect(findings).toEqual([]);
  });
});
