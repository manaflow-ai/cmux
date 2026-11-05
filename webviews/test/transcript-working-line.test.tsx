// l10n-allow-file: test fixture tool titles, not shipped UI.
// The running turn's status line, as Claude desktop draws it (#21604 row 2,
// transcript-task-list-in-progress.png): what the agent is doing now, before any work "Thinking"
// (transcript-codex-live-line.test.tsx covers the line naming a call in flight). No mark blinks before any of them (Leo, 2026-10-20: the
// three pulsing dots were "the blinking ascii"; the ticking time says the turn is alive).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ActivityLine } from "../src/agent-session/acpmux/conversation/ActivityLine";
import { pageClocks } from "../src/ui/pageClock";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { translate } from "../src/agent-session/acpmux/i18n";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
// A status line draws no mark before its words: no working mark, no activity dots, and
// its first child is the label itself. The plan activity line below uses the shared icon column.
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

test("a running label's shimmer includes its timer and uses the slow cadence", async () => {
  const html = renderToStaticMarkup(
    <Thinking
      since={at}
      doing="Read the Freestyle lanes note; check dispatcher"
      doingAt={at}
      now={() => at + 50_000}
    />,
  );
  expect(html).toContain('class="cv-shimmer__row"');
  expect(html).toContain('class="cv-shimmer__lit-time" data-text="50s"');
  const css = await Bun.file(new URL("../src/pages/shared/desktop.css", import.meta.url)).text();
  expect(css).toContain("--cmux-shimmer-period: 2.8s");
  expect(css).toMatch(/@keyframes cmux-shimmer-band[\s\S]*?45%[\s\S]*?100%/);
});

test("the line while the agent starts is Thinking, with no Cancel", () => {
  const html = renderToStaticMarkup(<Thinking starting />);
  expect(html).toContain("is-shimmer");
  expect(html).not.toContain(translate("switch.cancelPrompt"));
});

test("the activity line names the work in the shared icon column", () => {
  const html = renderToStaticMarkup(
    <ActivityLine row={row("act", "activity-line", { text: "Edit grid.css" })} now={() => at + 26_000} />,
  );
  expect(text(html)).toMatch(/^Edit grid\.css \d+s$/);
  expect(html).toContain('class="cv-tool__icon"');
  expect(html).not.toContain("cv-spinner");
  expect(html).not.toMatch(/cv-working-mark|cv-activity__dots/);
});

test("a running command keeps only its static terminal mark", () => {
  const html = renderToStaticMarkup(
    <ActivityLine
      row={row("command", "activity-line", { text: "bun test", doingCommand: true })}
      now={() => at + 26_000}
    />,
  );
  expect(html).toContain("cv-tool__icon");
  expect(html).toContain("<svg");
  expect(html).not.toContain("cv-spinner");
});

test("live activity lines share the page's one second and rest while the page is hidden", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT", "setInterval"];
  const saved = keys.map((key) => [key, scope[key]] as const);
  const dom = new JSDOM("<!doctype html><main id=root></main>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  let visibility = "visible";
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    get: () => visibility,
  });
  let intervals = 0;
  const realInterval = globalThis.setInterval;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
    setInterval: ((handler: () => void, ms?: number) => {
      intervals += 1;
      return realInterval(handler, ms);
    }) as unknown as typeof setInterval,
  });
  const root = createRoot(dom.window.document.getElementById("root")!);
  const lines = Array.from({ length: 5 }, (_, index) =>
    row(`act-${index}`, "activity-line", { text: `Edit grid-${index}.css` }),
  );
  try {
    act(() => root.render(lines.map((line) => <ActivityLine key={line.id} row={line} now={() => at + 26_000} />)));
    expect(dom.window.document.querySelectorAll(".cv-activity__time")).toHaveLength(5);
    expect(dom.window.document.querySelectorAll(".cv-activity > .cv-tool__icon")).toHaveLength(5);
    // Five live lines, one timer: none of their own, and the page clock's one for all of them.
    expect(intervals).toBe(0);
    expect(pageClocks(dom.window.document)).toMatchObject({ running: 1, subscribers: 5 });
    act(() => {
      visibility = "hidden";
      dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    });
    expect(pageClocks(dom.window.document)).toMatchObject({ running: 0, subscribers: 5 });
  } finally {
    act(() => root.unmount());
    dom.window.close();
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
  }
  expect(pageClocks(dom.window.document)).toEqual({ running: 0, subscribers: 0, items: [] });
});

test("no dots loop on the running line; only the word Thinking shimmers, in the theme accent", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  expect(css).not.toContain("cv-thinking-sweep");
  expect(css).not.toMatch(/cv-working-mark|cv-working-dot|cv-activity__dots|cv-activity-dot/);
  // The sweep runs only with motion allowed and the status look not static, on the shared clock's
  // keyframes (two transform loops, ShimmerText.tsx), its lit words mixed from the theme accent
  // (never a literal color). working-loops-compositor.test.tsx checks the loops in the engines.
  const rule = (selector: string) =>
    css.match(new RegExp(`:root:not\\(\\[data-status-indicators="static"\\]\\) \\${selector} \\{([^}]*)\\}`));
  const band = rule(".cv-shimmer__band");
  const lit = rule(".cv-shimmer__lit");
  expect(band![1]).toContain("animation: cmux-shimmer-band");
  expect(lit![1]).toContain("animation: cmux-shimmer-lit");
  expect(lit![1]).toContain("var(--agent-accent");
  expect(lit![1]).not.toMatch(/#[0-9a-f]{3,8}\b|rgb\(|orange/i);
});


