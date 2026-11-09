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

// Leo, 2026-11-06, hovering the chat's right edge over "8s · 2m5 1.4K toke": "this flickers". The hint
// keeps its room while it is offered (backgroundHintRoom.experiment.ts), so pointing at the line
// changes its opacity alone: no rule under the pointer moves it or gives it room it lacked at rest.
test("pointing at the live line changes only the background command hint's opacity", () => {
  const hidden = rules.find(
    ({ rule, media }) => !media.length && rule.selectorText === ":is(.cv-worked, .cv-activity) .cv-command__bg",
  );
  expect(hidden?.rule.style.position).toBe("");
  expect(hidden?.rule.style.flexShrink).toBe("0");
  expect(hidden?.rule.style.opacity).toBe("0");
  const pointed = rules.filter(
    ({ rule }) => rule.selectorText.includes(".cv-command__bg") && /:hover|:focus-visible/.test(rule.selectorText),
  );
  expect(pointed.length).toBeGreaterThan(0);
  // Paint may change under the pointer (its own lift); nothing that lays it out may.
  const layout =
    /^(position|display|inset|top|right|bottom|left|width|height|min-|max-|margin|padding|flex|gap|font|letter-spacing)/;
  for (const { rule } of pointed)
    for (let index = 0; index < rule.style.length; index++)
      expect({
        rule: rule.selectorText,
        layout: layout.test(rule.style.item(index)) && rule.style.item(index),
      }).toEqual({
        rule: rule.selectorText,
        layout: false,
      });
});

// Leo, 2026-11-06, on a dark box behind a received line's "just now": "this just now has this weird
// background". The line's action slot lay over the preview's tail on a fill of the pane's own ground,
// which a translucent window shows as a plate. It keeps its room at the line's end instead, and no
// rule paints under it, the held line's (multiplayer.css) included.
test("a received line's action slot keeps its room and paints no plate", () => {
  const slot = rules.find(({ rule, media }) => !media.length && rule.selectorText === ".cv-received__hover");
  expect(slot?.rule.style.position).toBe("");
  expect(slot?.rule.style.flexShrink).toBe("0");
  const held = new JSDOM("<!doctype html>").window.document;
  const sheet = held.createElement("style");
  sheet.textContent = readFileSync(
    new URL("../src/agent-session/acpmux/multiplayer/multiplayer.css", import.meta.url),
    "utf8",
  );
  held.head.append(sheet);
  const heldRules = Array.from(sheet.sheet!.cssRules).filter((rule): rule is CSSStyleRule => "selectorText" in rule);
  for (const { rule } of [...rules, ...heldRules.map((rule) => ({ rule }))])
    if (rule.selectorText.includes(".cv-received__hover")) {
      expect(rule.style.getPropertyValue("background")).toBe("");
      expect(rule.style.getPropertyValue("background-image")).toBe("");
    }
});
