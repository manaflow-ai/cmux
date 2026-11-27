// cmux#38791 review: a permission card is drawn in the chat's interface font (Settings > Agent
// Chat > Interface Font sets `--font-ui`), so its first estimate measures that face, not the type
// scale's system stack.
import { expect, test } from "bun:test";
import { setChatDisplay } from "../chatDisplay";
import { CHAT_UI_FONT_KEY } from "../chatUiFont";
import { cardFont, cardLetterSpacing, permissionCardHeight } from "./cardHeight";
import type { AcpmuxPermission } from "../model";
import type { AgentQuestion } from "../question/model";
import answered from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-collapsed.json";
import pending from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";

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

// cmux#38886 review: a permission card's buttons draw their body-size label with the detail step's
// letter-spacing (styles.css `.acpmux-permission-ask .acpmux-permission-buttons button`), so their
// widths measure that step's tracking, not the body step's that their size would name.
test("a permission card's buttons measure the detail step's letter-spacing at body size", () => {
  setChatDisplay({ [CHAT_UI_FONT_KEY]: "inter-tuned" });
  expect(cardLetterSpacing(13, "detail")).toBeCloseTo(0.0005 * 13);
  expect(cardLetterSpacing(13)).toBeCloseTo(-0.0032 * 13);
  setChatDisplay({});
});

test("normal question estimates track the reading size and a footer that wraps", () => {
  const permission = { question: pending as AgentQuestion } as AcpmuxPermission;
  setChatDisplay({});
  const wide = permissionCardHeight(permission, 640);
  const narrow = permissionCardHeight(permission, 280);
  expect(narrow).toBeGreaterThan(wide);
  setChatDisplay({ "agentPane.display.font.size": 24 });
  expect(permissionCardHeight(permission, 640)).toBeGreaterThan(wide);
  setChatDisplay({});
  expect(permissionCardHeight(permission, 640)).toBe(wide);
});

test("an answered question bubble wraps and follows the chat reading size", () => {
  const permission = { question: answered as AgentQuestion } as AcpmuxPermission;
  setChatDisplay({});
  setChatDisplay({ "agentPane.display.font.preset": "serif" });
  const wide = permissionCardHeight(permission, 640);
  expect(permissionCardHeight(permission, 280)).toBeGreaterThan(wide);
  const multiline = {
    ...answered,
    items: answered.items.map((item) => ({ ...item, prompt: "First line\nSecond line\nThird line" })),
  } as AgentQuestion;
  expect(permissionCardHeight({ question: multiline } as AcpmuxPermission, 640)).toBeGreaterThan(wide);
  setChatDisplay({ "agentPane.display.font.size": 24 });
  expect(permissionCardHeight(permission, 640)).toBeGreaterThan(wide);
  setChatDisplay({});
});
