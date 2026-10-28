// The prompt editor's Send (UserBubble's PromptEditor) is the theme inverted, a text-color fill, so its
// label needs an opaque page color: --agent-surface is a translucent tint and drew white on white in
// dark themes.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");

/** The declarations of the rule whose selector list is exactly `selector`. */
const rule = (selector: string) => {
  const flat = css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\s+/g, " ");
  const at = flat.indexOf(`${selector} {`);
  if (at < 0) throw new Error(`no rule ${selector}`);
  const open = flat.indexOf("{", at);
  return flat.slice(open + 1, flat.indexOf("}", open)).trim();
};

test("the editor's Send label is the opaque page color on the text-color fill", () => {
  const send = rule(".cv-user__edit-button--send");
  expect(send).toMatch(/background: ?var\(--cv-text\)/);
  expect(send).toMatch(/(^|; ?)color: ?var\(--cmux-surface-solid\b/);
  expect(send).not.toMatch(/(^|; ?)color: ?var\(--agent-(surface|page-bg)\b/);
});
