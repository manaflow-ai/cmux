import { expect, test } from "bun:test";
import { STRING_TABLES } from "../i18n";
import { translateNewTab } from "./strings";

// The new tab screen's strings are the `newTab.` keys of the pane's table (i18n.test.ts checks
// every language has every key with the same placeholders).
test("the new tab screen's strings are in the pane's table", () => {
  expect(Object.keys(STRING_TABLES.en!).filter((key) => key.startsWith("newTab.")).length).toBeGreaterThan(10);
});

test("placeholders fill in any language", () => {
  expect(translateNewTab("row.ask", { agent: "Codex" }, "en")).toBe("Ask Codex");
  expect(translateNewTab("row.ask", { agent: "Codex" }, "ja")).toBe("Codexに質問");
});
