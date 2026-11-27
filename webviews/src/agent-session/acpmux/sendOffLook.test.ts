// Send, Stop and the queue's Send are plain glyphs, as the mic is (Leo 2026-10-21: "WHY ARE THERE
// CIRCLES. Use plain glyphs like the mic ... A hover state is fine, but no solid discs."). No rule
// of the pane's sheets fills them at rest, pressed, ready or off: only hover (and keyboard focus,
// which shows the hover) takes the composer's soft pill. The off Send (an empty draft, or Send
// turned off while the folder's trust question is open) is the same glyph, dimmed. Every one draws in
// the pane's secondary text color (--agent-muted, the mic's), never the full text color, and hover
// changes only the background.
// test/composer-plain-glyphs.test.ts measures the same in Chromium and WebKit.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const sheet = (name: string) => readFileSync(join(import.meta.dir, name), "utf8");
const SHEETS = ["styles.css", "composerStates.css", "composerLocation.css", "newtab/screen.css"].map(
  (name) => [name, sheet(name)] as const,
);

/** Every rule of `css` as its selector list and declarations, at any @media depth. */
const rules = (css: string) => {
  const flat = css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\s+/g, " ");
  const found: { selector: string; body: string }[] = [];
  const walk = (text: string) => {
    let at = 0;
    while (at < text.length) {
      const open = text.indexOf("{", at);
      if (open < 0) return;
      const head = text.slice(at, open).trim();
      let depth = 1;
      let close = open + 1;
      for (; close < text.length && depth > 0; close++) {
        if (text[close] === "{") depth++;
        else if (text[close] === "}") depth--;
      }
      const inner = text.slice(open + 1, close - 1);
      if (head.startsWith("@")) walk(inner);
      else found.push({ selector: head, body: inner });
      at = close;
    }
  };
  walk(flat);
  return found;
};

const SEND = /\.acpmux-(?:send|cancel)\b/;
/** A selector of the list that names Send or Stop itself (not a descendant of it). */
const namesSend = (selector: string) =>
  selector.split(",").filter((part) => {
    const last =
      part
        .trim()
        .split(/\s+|>|\+|~/)
        .at(-1) ?? "";
    return SEND.test(last);
  });
const background = (body: string) => /(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)/.exec(body)?.[1]?.trim();
const CLEAR = /^(?:none|transparent|0 0)$/;
/** The composer's soft hover pill: the row's hover wash (the mic's and +'s). */
const PILL = /^var\(--acpmux-(?:row-hover|composer-hover)/;

test("no rule fills Send or Stop at rest, pressed, ready or off: no disc anywhere", () => {
  const fills: string[] = [];
  for (const [name, css] of SHEETS)
    for (const { selector, body } of rules(css)) {
      const fill = background(body);
      if (fill === undefined || CLEAR.test(fill)) continue;
      for (const part of namesSend(selector)) {
        // Hover (and keyboard focus, which shows the hover) may take the soft pill; nothing else fills.
        const hover = /:hover|:focus-visible/.test(part);
        if (hover && PILL.test(fill)) continue;
        fills.push(`${name}: ${part.trim()} { background: ${fill} }`);
      }
    }
  expect(fills).toEqual([]);
});

test("a press shows nothing more than the hover pill", () => {
  const pressed: string[] = [];
  for (const [name, css] of SHEETS)
    for (const { selector, body } of rules(css))
      for (const part of namesSend(selector))
        if (/:active/.test(part) && background(body) !== undefined) pressed.push(`${name}: ${part.trim()}`);
  expect(pressed).toEqual([]);
});

test("the disc's colors are gone, and the off Send is the dimmed text color", () => {
  const styles = sheet("styles.css");
  expect(styles).not.toMatch(/--acpmux-send-(?:fill|ink|off-bg)\s*:/);
  const off = /--acpmux-send-off-fg:color-mix\(in srgb,var\(--agent-text\) (\d+)%,transparent\)/.exec(styles);
  expect(off).not.toBeNull();
  // Dimmed: clearly below the text, still legible on the composer.
  expect(Number(off![1])).toBeGreaterThanOrEqual(30);
  expect(Number(off![1])).toBeLessThanOrEqual(60);
  // The empty draft's Send and Send turned off share that one color.
  const offRules = [...rules(styles), ...rules(sheet("composerStates.css"))].filter(
    ({ selector }) =>
      /\.acpmux-send(?::not\([^)]*\))*:not\(\.acpmux-send-ready\)/.test(selector) && !/:hover/.test(selector),
  );
  expect(offRules.length).toBeGreaterThan(0);
  for (const { body } of offRules) expect(body).toMatch(/color: ?var\(--acpmux-send-off-fg\)/);
});

const color = (body: string) => /(?:^|;)\s*color\s*:\s*([^;]+)/.exec(body)?.[1]?.trim();

test("Send and Stop draw in the secondary text color, the off Send's dim, or the armed Stop's accent", () => {
  const inks: string[] = [];
  let base = false;
  for (const [name, css] of SHEETS)
    for (const { selector, body } of rules(css)) {
      const ink = color(body);
      if (ink === undefined) continue;
      for (const part of namesSend(selector)) {
        const at = part.trim();
        if (at === ".acpmux-send" && ink === "var(--agent-muted)") base = true;
        if (ink === "var(--agent-muted)" || ink === "var(--acpmux-send-off-fg)") {
          // Hover keeps the glyph's color: only the background changes.
          if (/:hover/.test(at)) inks.push(`${name}: ${at} { color: ${ink} }`);
          continue;
        }
        if (/\[data-escape-armed\]/.test(at) && /--agent-(?:lit-glyph|accent)/.test(ink)) continue;
        inks.push(`${name}: ${at} { color: ${ink} }`);
      }
    }
  expect(inks).toEqual([]);
  expect(base).toBe(true);
});
