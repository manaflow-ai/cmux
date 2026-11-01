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

// Leo, 2026-10-24: "if the command is too long, hide it under the run in background? ... hide it
// when hovering in that area". Hidden, the hint takes no room on the live line, so a long command
// runs to its end; on hover it takes its room back and the command's tail goes under it.
test("the hidden background command hint takes no room on the live line", () => {
  const hidden = rules.find(
    ({ rule, media }) => !media.length && rule.selectorText === ":is(.cv-worked, .cv-activity) .cv-command__bg",
  );
  expect(hidden?.rule.style.position).toBe("absolute");
  expect(hidden?.rule.style.opacity).toBe("0");
  const hovered = rules.find(
    ({ rule, media }) => !media.length && rule.selectorText === ":is(.cv-worked, .cv-activity):hover .cv-command__bg",
  );
  expect(hovered?.rule.style.position).toBe("static");
  expect(hovered?.rule.style.opacity).toBe("1");
});
