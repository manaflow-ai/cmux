// cmux#38791 review: a permission card is drawn in the chat's interface font (Settings > Agent
// Chat > Interface Font sets `--font-ui`), so its first estimate measures that face, not the type
// scale's system stack.
import { expect, test } from "bun:test";
import { setChatDisplay } from "../chatDisplay";
import { CHAT_UI_FONT_KEY } from "../chatUiFont";
import { cardFont, cardLetterSpacing } from "./cardHeight";

test("a permission card measures the chat's interface font", () => {
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "verdana" });
  expect(cardFont()).toStartWith("Verdana");
  setChatDisplay({});
  expect(cardFont()).toBe("-apple-system, BlinkMacSystemFont, system-ui, sans-serif");
});

// cmux#38857 review: System UI and System UI, tight (and cmux Inter and stock Inter) share a stack
// but not their letter-spacing, so the card measures each step's tracking as the page draws it.
test("a permission card measures the interface font's letter-spacing", () => {
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "system-ui-tight" });
  expect(cardLetterSpacing(13)).toBeCloseTo(-0.008 * 13);
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "inter-tuned" });
  expect(cardLetterSpacing(13)).toBeCloseTo(-0.0032 * 13);
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "inter" });
  expect(cardLetterSpacing(13)).toBe(0);
  setChatDisplay({});
  expect(cardLetterSpacing(13)).toBe(0);
});
