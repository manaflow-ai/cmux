import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const css = readFileSync(
  process.env.TRANSCRIPT_HOVER_CSS ??
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  "utf8",
);
const dom = new JSDOM("<!doctype html>");
const style = dom.window.document.createElement("style");
style.textContent = css;
dom.window.document.head.append(style);
const rules: { rule: CSSStyleRule; media: string[] }[] = [];
function collect(list: CSSRuleList, media: string[] = []) {
  for (const rule of Array.from(list)) {
    if (rule.type === dom.window.CSSRule.MEDIA_RULE) {
      const group = rule as CSSMediaRule;
      collect(group.cssRules, [...media, group.conditionText]);
    } else if (rule.type === dom.window.CSSRule.STYLE_RULE) {
      rules.push({ rule: rule as CSSStyleRule, media });
    }
  }
}
collect(style.sheet!.cssRules);

const actions = [".cv-user__actions", ".cv-received-actions", ".cv-turn-actions"];

test("transcript hover fades require motion preference and a hover-capable fine pointer", () => {
  const fades = rules.filter(
    ({ rule }) =>
      actions.some((action) => rule.selectorText.includes(action)) &&
      rule.style.getPropertyValue("transition") &&
      // Always-visible pending controls disable transitions; that is not a hover fade.
      rule.style.getPropertyValue("transition") !== "none" &&
      !rule.selectorText.includes(":focus"),
  );
  expect(fades.length).toBeGreaterThan(0);
  for (const { media } of fades) {
    const conditions = media.join(" and ");
    expect(conditions).toContain("(prefers-reduced-motion: no-preference)");
    expect(conditions).toContain("(hover: hover)");
    expect(conditions).toContain("(pointer: fine)");
  }
});

test("keyboard focus and action visibility remain independent of pointer capability", () => {
  for (const action of actions) {
    const focus = rules.find(
      ({ rule }) => rule.selectorText.includes(`${action}:focus-within`) && rule.style.getPropertyValue("transition"),
    );
    expect(focus).toBeDefined();
    expect(focus!.media).toEqual(["(prefers-reduced-motion: no-preference)"]);
    expect(focus!.rule.style.getPropertyValue("transition")).not.toContain("--cv-actions-in-delay");
    const visibility = rules.filter(({ rule }) => rule.selectorText.includes(action) && rule.style.opacity === "1");
    expect(visibility.length).toBeGreaterThan(0);
    for (const { media } of visibility) expect(media).toEqual([]);
  }
});

test("the background command hint has no delayed entrance animation", () => {
  const hints = rules.filter(({ rule }) => rule.selectorText.includes(".cv-command__bg"));
  expect(hints.length).toBeGreaterThan(0);
  for (const { rule } of hints) {
    expect(["", "none"]).toContain(rule.style.getPropertyValue("animation"));
    expect(rule.style.getPropertyValue("animation-delay")).toBe("");
  }
});
