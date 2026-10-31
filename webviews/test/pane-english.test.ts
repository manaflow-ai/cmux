// The agent pane has no hard-coded English: every string a person reads comes from its table
// (acpmux/Localizable.xcstrings), so the pane follows the app's language. test/pane-english.ts
// finds rendered literals; a deliberate exception carries an `l10n-allow: <reason>` comment.
import path from "node:path";
import { describe, expect, test } from "bun:test";
import { scan } from "./pane-english";

const FIXTURES = path.resolve(import.meta.dir, "fixtures/pane-english");

describe("agent pane strings", () => {
  test("no user-visible English is written in the pane's sources", () => {
    const findings = scan().map((finding) => `${finding.file}:${finding.line} ${JSON.stringify(finding.text)}`);
    expect(findings).toEqual([]);
  });

  test("an Error's text and a message's fallback count through ?? and ||", () => {
    const findings = scan(FIXTURES).filter((finding) => finding.file === "shipped/fallbacks.ts");
    expect(findings.map((finding) => finding.text)).toEqual([
      "Run snapshot failed ({})",
      "Could not read the run",
      "Run board is unavailable",
    ]);
  });

  test("a file exempt as not shipped stops being exempt once shipped code imports it", () => {
    const findings = scan(FIXTURES).filter((finding) => finding.file !== "shipped/fallbacks.ts");
    expect(findings.map((finding) => `${finding.file}:${finding.line} ${finding.text}`).sort()).toEqual([
      "shipped/lazyPrototype.ts:2 imports board/Board.tsx, which is exempt as not shipped",
      "shipped/usesPrototype.ts:2 imports board/Board.tsx, which is exempt as not shipped",
    ]);
  });
});
