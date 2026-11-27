import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");

test("the classic New Tab kind handoff keeps both motion controls active", () => {
  const dom = new JSDOM("<!doctype html>");
  const style = dom.window.document.createElement("style");
  style.textContent = css;
  dom.window.document.head.append(style);

  const rules = [...(style.sheet?.cssRules ?? [])];
  const kindSwitchMedia = rules.find(
    (rule) =>
      rule.type === dom.window.CSSRule.MEDIA_RULE &&
      rule.cssText.includes(".acpmux-newtab-row[data-kind-switch]") &&
      rule.cssText.includes("animation: none"),
  ) as CSSMediaRule | undefined;
  expect(kindSwitchMedia?.media.mediaText).toBe("(prefers-reduced-motion: reduce)");

  const motionOffRule = rules.find(
    (rule) =>
      rule.type === dom.window.CSSRule.STYLE_RULE &&
      rule.cssText.includes(':root[data-agent-motion="off"]') &&
      rule.cssText.includes(".acpmux-newtab-row[data-kind-switch]"),
  );
  expect(motionOffRule?.cssText).toContain("animation: none");
});
