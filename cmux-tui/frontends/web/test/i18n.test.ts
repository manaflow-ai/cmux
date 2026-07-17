import { describe, expect, it } from "vitest";
import { messages } from "../src/i18n";

describe("web localization catalogs", () => {
  it("keeps English and Japanese message keys in parity", () => {
    expect(Object.keys(messages.ja).sort()).toEqual(Object.keys(messages.en).sort());
  });
});
