import { describe, expect, it, vi } from "vitest";
import { messages, t } from "../src/i18n";
import { SUPPORTED_PROTOCOL } from "../src/lib/protocol";

describe("web localization catalogs", () => {
  it("keeps English and Japanese message keys in parity", () => {
    expect(Object.keys(messages.ja).sort()).toEqual(Object.keys(messages.en).sort());
  });

  it.each([
    ["en-US", "Protocol 9 is required; the server reported protocol 7."],
    ["ja-JP", "プロトコル9が必要ですが、サーバーはプロトコル7を返しました。"],
  ])("renders the required protocol in %s mismatch errors", (language, expected) => {
    const languageSpy = vi.spyOn(navigator, "language", "get").mockReturnValue(language);
    expect(t("wrongProtocol", { required: SUPPORTED_PROTOCOL, protocol: 7 })).toBe(expected);
    languageSpy.mockRestore();
  });
});
