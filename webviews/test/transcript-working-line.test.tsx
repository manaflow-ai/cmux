// l10n-allow-file: test fixture tool titles, not shipped UI.
// The running turn's status line, as Claude desktop draws it (#21604 row 2,
// transcript-task-list-in-progress.png): what the agent is doing now, before any work "Thinking"
// (transcript-codex-live-line.test.tsx covers the line naming a call in flight). No mark blinks before any of them (Leo, 2026-10-20: the
// three pulsing dots were "the blinking ascii"; the ticking time says the turn is alive).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { translate } from "../src/agent-session/acpmux/i18n";

const at = 1_000;

// A status line draws no mark before its words: no working mark, no activity dots, and
// its first child is the label itself.
const stillMarkup = (html: string) =>
  /^<div[^>]*>(?:<span class="cv-shimmer__row">)?<(?:span|output) class="cv-(?:worked__label|thinking|activity__label)/.test(
    html,
  ) && !/cv-working-mark|cv-activity__dots/.test(html);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("Thinking is the word alone, with no mark before it; the word itself shimmers", () => {
  const html = renderToStaticMarkup(<Thinking />);
  expect(text(html)).toBe("Thinking");
  expect(stillMarkup(html)).toBe(true);
  expect(html).toContain('class="cv-thinking is-shimmer"');
});

test("a running label's shimmer lights its words alone, not its timer, and uses the slow cadence", async () => {
  const html = renderToStaticMarkup(
    <Thinking
      since={at}
      doing="Read the Freestyle lanes note; check dispatcher"
      doingAt={at}
      now={() => at + 50_000}
    />,
  );
  expect(html).toContain('class="cv-shimmer__row"');
  // The band lights the words only: no lit copy of "50s" for the glimmer to run onto at the end of its
  // pass (Leo, 2026-11-25: "and the overlap when the glimmer goes to the end").
  expect(html).not.toContain("cv-shimmer__lit-time");
  expect(html).toContain(">50s<");
  const css = await Bun.file(new URL("../src/pages/shared/desktop.css", import.meta.url)).text();
  expect(css).toContain("--cmux-shimmer-period: 2.8s");
  expect(css).toMatch(/@keyframes cmux-shimmer-band[\s\S]*?45%[\s\S]*?100%/);
});

test("the line while the agent starts is Thinking, with no Cancel", () => {
  const html = renderToStaticMarkup(<Thinking starting />);
  expect(html).toContain("is-shimmer");
  expect(html).not.toContain(translate("switch.cancelPrompt"));
});

test("no dots loop on the running line; only the word Thinking shimmers, in the theme foreground", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).not.toContain("cv-thinking-sweep");
  expect(css).not.toMatch(/cv-working-mark|cv-working-dot|cv-activity__dots|cv-activity-dot/);
  // The base layers rest outside the mask; a cadence class starts each compositor-only sweep.
  const rule = (selector: string) =>
    css.match(new RegExp(`:root:not\\(\\[data-status-indicators="static"\\]\\) \\${selector} \\{([^}]*)\\}`));
  const band = rule(".cv-shimmer__band");
  const lit = rule(".cv-shimmer__lit");
  expect(band![1]).toContain("transform: translateX(-50%)");
  expect(css).toContain("animation: cmux-cadenced-shimmer-band var(--cv-shimmer-sweep-duration)");
  expect(css).toContain("animation: cmux-cadenced-shimmer-lit var(--cv-shimmer-sweep-duration)");
  expect(lit![1]).toContain("color: var(--cv-text)");
  expect(lit![1]).not.toMatch(/#[0-9a-f]{3,8}\b|rgb\(|orange/i);
});
