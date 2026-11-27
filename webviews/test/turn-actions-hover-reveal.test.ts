// A turn's action row (Copy, Fork, Pin, Read aloud, ⋯, then its age) is hidden at rest (the chat's
// last reply's buttons excepted, Lucas 2026-11-26) and shows,
// on a super fast fade, while the pointer is on that turn or a key is inside it, as Claude Code
// desktop's (Leo, 2026-11-22: "claude hides buttons until you hover over the relevant area of a turn
// response. they do a SUPER FAST fade in and fade out for it. which i like. and you hover and you get
// the timing ... i think we go with claude code here. idk when we decided to always show all buttons
// always. let's not"). This reads conversation.css and TurnRows.tsx; test/reply-footer.test.ts plays
// it in a browser (hidden at rest, shown with its age on hover and on keyboard focus, no row moving).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const DIR = path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation");
const css = readFileSync(path.join(DIR, "conversation.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const turnRows = readFileSync(path.join(DIR, "TurnRows.tsx"), "utf8");

/// Every rule's selector list and body, at any @media depth.
const rules = [...css.matchAll(/([^{};]+)\{([^{}]*)\}/g)].map((match) => ({
  selectors: match[1]
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^@media[^{]*$/, "")
    .split(/,(?![^(]*\))/)
    .map((part) => part.trim())
    .filter(Boolean),
  body: match[2],
}));
const opacityOne = (rule: { body: string }) => /(^|;)\s*opacity:\s*1\s*(;|$)/.test(rule.body);

describe("a turn's action row", () => {
  test("is hidden at rest", () => {
    const rest = rules.filter((rule) => rule.selectors.includes(".acpmux-turnSummary .cv-turn-actions"));
    expect(rest.some((rule) => /(^|;)\s*opacity:\s*0\s*(;|$)/.test(rule.body))).toBe(true);
  });

  test("no rule shows a finished turn's row at rest (the 2026-11-03 rule, cmux#34939)", () => {
    const alwaysOn = rules
      .filter(opacityOne)
      .flatMap((rule) => rule.selectors)
      .filter((selector) => /\.cv-turn-actions(?![\w-])/.test(selector))
      .filter(
        (selector) =>
          !/:hover|:focus|data-turn-revealed|data-popup-open|data-popup-within|data-reading|--failed|--resumable|--final-footer/.test(
            selector,
          ),
      );
    expect(alwaysOn).toEqual([]);
  });

  test("shows at rest on the chat's last reply only (Lucas, 2026-11-26), its age still on hover", () => {
    const shown = rules.filter(opacityOne).flatMap((rule) => rule.selectors);
    expect(shown).toContain(
      ".acpmux-turnSummary.acpmux-row--final-footer .cv-turn-actions:not(.cv-turn-actions--waiting)",
    );
    expect(shown.filter((selector) => /--final-footer/.test(selector) && /\.cv-turn-time/.test(selector))).toEqual([]);
  });

  test("shows for the pointer on the turn and for keyboard focus inside it", () => {
    const shown = rules.filter(opacityOne).flatMap((rule) => rule.selectors);
    for (const selector of [
      ".acpmux-turnSummary[data-turn-revealed] .cv-turn-actions",
      ".acpmux-turnSummary:hover .cv-turn-actions",
      ".acpmux-turnSummary:focus-visible .cv-turn-actions",
      ".acpmux-turnSummary .cv-turn-actions:has(:focus-visible)",
    ])
      expect(shown).toContain(selector);
  });

  test("fades in and out on the micro and quick motion steps, as Claude's, keeping Reduce Motion's 0 s", () => {
    const fade = rules.find(
      (rule) => rule.selectors.includes(".cv-turn-actions") && /--cv-actions-in:/.test(rule.body),
    );
    expect(fade).toBeDefined();
    expect(fade!.selectors).toEqual(expect.arrayContaining([".cv-turn-actions", ".cv-reply-actions"]));
    expect(fade!.body).toMatch(
      /--cv-actions-in:\s*min\(var\(--cmux-hover-reveal-in\),\s*var\(--cmux-motion-micro, 120ms\)\)/,
    );
    expect(fade!.body).toMatch(
      /--cv-actions-out:\s*min\(var\(--cmux-hover-reveal-out\),\s*var\(--cmux-motion-quick, 80ms\)\)/,
    );
    const scale = readFileSync(path.resolve(import.meta.dir, "../src/pages/shared/desktop.css"), "utf8");
    const ms = (name: string) => Number(scale.match(new RegExp(`${name}:\\s*(\\d+)ms`))?.[1]);
    for (const name of ["--cmux-motion-micro", "--cmux-motion-quick"]) {
      expect(ms(name)).toBeGreaterThanOrEqual(80);
      expect(ms(name)).toBeLessThanOrEqual(120);
    }
  });

  test("draws the reply's age after its buttons", () => {
    const footer = turnRows.slice(turnRows.indexOf('<MessageFooterRow className="cv-turn-footer-row">'));
    const group = footer.indexOf("cv-turn-action-group");
    const time = footer.indexOf("<ReplyTime at={row.at}");
    expect(group).toBeGreaterThan(-1);
    expect(time).toBeGreaterThan(group);
    expect(time).toBeLessThan(footer.indexOf("</MessageFooterRow>"));
  });
});
