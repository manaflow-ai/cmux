// l10n-allow-file: message preview regression inputs, not shipped UI.
import { expect, test } from "bun:test";
import { messagePreview as sentPreview } from "./AgentMessageRow";
import { messagePreview as receivedPreview } from "./incomingMessage";

for (const [direction, preview] of [
  ["sent", sentPreview],
  ["received", receivedPreview],
] as const) {
  test(`${direction}: preview cutoff keeps whole Unicode characters`, () => {
    for (const symbol of ["🦊", "👍🏽", "👩‍💻", "🇯🇵", "e\u0301"]) {
      const before = "i".repeat(239);
      expect(preview(before + symbol + " later")).toBe(before);
      const fits = "i".repeat(240 - symbol.length) + symbol;
      expect(preview(fits + " later")).toBe(fits);
    }
  });

  test(`${direction}: ordinary and short previews keep their current content`, () => {
    expect(preview("x".repeat(400))).toBe("x".repeat(240));
    expect(preview("\n# **Ready** 🦊  now\nOther line")).toBe("Ready 🦊 now");
    expect(preview("")).toBe("");
  });
}
