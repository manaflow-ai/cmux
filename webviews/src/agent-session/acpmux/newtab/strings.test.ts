import { expect, test } from "bun:test";
import { NEW_TAB_STRING_TABLES, translateNewTab } from "./strings";

test("every new tab string has English and Japanese text with the same placeholders", () => {
  const { en, ja } = NEW_TAB_STRING_TABLES;
  expect(Object.keys(ja).sort()).toEqual(Object.keys(en).sort());
  for (const key of Object.keys(en) as (keyof typeof en)[]) {
    expect(ja[key].length).toBeGreaterThan(0);
    expect(ja[key].match(/\{\w+\}/g) ?? []).toEqual(en[key].match(/\{\w+\}/g) ?? []);
  }
});

test("placeholders fill in either language", () => {
  expect(translateNewTab("row.ask", { agent: "Codex" }, "en")).toBe("Ask Codex");
  expect(translateNewTab("row.ask", { agent: "Codex" }, "ja")).toBe("Codexに質問");
});
