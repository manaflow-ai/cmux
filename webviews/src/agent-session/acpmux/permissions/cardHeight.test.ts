// cmux#38791 review: a permission card is drawn in the chat's interface font (Settings > Agent
// Chat > Interface Font sets `--font-ui`), so its first estimate measures that face, not the type
// scale's system stack.
import { expect, test } from "bun:test";
import { setChatDisplay } from "../chatDisplay";
import { CHAT_UI_FONT_KEY } from "../chatUiFont";
import { cardFont } from "./cardHeight";

test("a permission card measures the chat's interface font", () => {
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "verdana" });
  expect(cardFont()).toStartWith("Verdana");
  setChatDisplay({});
  expect(cardFont()).toBe("-apple-system, BlinkMacSystemFont, system-ui, sans-serif");
});
