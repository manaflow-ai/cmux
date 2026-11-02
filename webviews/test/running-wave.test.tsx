// RUNNING-WAVE (Leo 2026-10-21: the Subagents avatars, now its running lines, "glimmer at different
// intervals ... it would look cool if they went in a wave, like how thinking glimmers in ChatGPT").
// Running indicators side by side share one shimmer: consecutive wave indices for the running ones,
// none for finished or failed ones, one shared start for every item, and no wave under Reduce
// Motion or the motion gate. running-wave-loops.test.ts runs the stylesheet in Chromium.
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { SubagentsSection } from "../src/agent-session/acpmux/session-info/SubagentsSection";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { SpinnerAnimation } from "../src/ui/spinnerClock";
import { alignWave, WAVE_CLASS, WAVE_KEYFRAMES, waveIndices, waveProps } from "../src/ui/wave";

type Item = { id: string; state: "running" | "done" | "failed" };
const live = (item: Item) => item.state === "running";

test("running items get consecutive wave indices in display order; finished and failed get none", () => {
  const items: Item[] = [
    { id: "a", state: "running" },
    { id: "b", state: "done" },
    { id: "c", state: "running" },
    { id: "d", state: "failed" },
    { id: "e", state: "running" },
  ];
  expect(waveIndices(items, live)).toEqual([0, undefined, 1, undefined, 2]);
  expect(waveIndices([], live)).toEqual([]);
  expect(waveIndices([{ id: "x", state: "done" }], live)).toEqual([undefined]);
});

test("an item in the wave takes the wave class and its index; one outside takes nothing", () => {
  expect(waveProps(3)).toEqual({ className: WAVE_CLASS, style: { "--wave-index": 3 } as never });
  expect(waveProps(0).className).toBe(WAVE_CLASS);
  expect(waveProps(undefined)).toEqual({});
});

test("every wave loop takes one shared start, so only its index offsets it", () => {
  const period = 1_600;
  const origin = 1_760_000_000_321; // performance.timeOrigin
  const loop = (name = WAVE_KEYFRAMES): SpinnerAnimation => ({
    animationName: name,
    startTime: null,
    effect: { getTiming: () => ({ duration: period }) },
  });
  // Items that start at different moments (an avatar that appears later).
  const items = [loop(), loop(), loop()];
  expect(alignWave(items[0], 10_000, origin)).toBe(true);
  expect(alignWave(items[1], 10_000 + 7 * period, origin)).toBe(true);
  expect(alignWave(items[2], 10_000 + 3 * period + 1, origin)).toBe(true);
  // One epoch: each start is a whole number of periods of Unix time.
  for (const item of items) expect(((item.startTime as number) + origin) % period).toBeCloseTo(0, 6);
  // Two loops started within one period get the very same start.
  const twin = loop();
  alignWave(twin, 10_000 + 7 * period + 5, origin);
  expect(twin.startTime).toBe(items[1].startTime);
  // Other loops are left alone.
  const other = loop("cmux-spin");
  expect(alignWave(other, 10_000, origin)).toBe(false);
  expect(other.startTime).toBeNull();
});

const agent = (id: string, state: string, startedAt: number): Subagent => ({
  id,
  parent: null,
  name: id,
  kind: "Explore",
  task: id,
  state,
  startedAt,
});

test("Session Info's running Subagents lines are in the wave, top to bottom; the ended row stays still", () => {
  const agents = [
    agent("done-1", "completed", 5),
    agent("run-old", "running", 1),
    agent("failed-1", "failed", 4),
    agent("run-new", "running", 3),
  ];
  const html = renderToStaticMarkup(<SubagentsSection agents={agents} waiting={new Set()} onOpen={() => {}} />);
  // Running lines keep their wave; the collapsed ended row renders still avatars.
  const icons = [
    ...html.matchAll(/<span class="acpmux-lineage__icon([^"]*)"(?: style="([^"]*)")? data-state="(\w+)"/g),
  ];
  expect(icons.map((match) => [match[3], match[1].trim(), match[2] ?? ""])).toEqual([
    ["running", WAVE_CLASS, "--wave-index:0"],
    ["running", WAVE_CLASS, "--wave-index:1"],
  ]);
  const dom = new JSDOM(html);
  try {
    const ended = dom.window.document.querySelector(".acpmux-session-info-subagents__ended")!;
    expect(ended.getAttribute("aria-expanded")).toBe("false");
    expect(ended.textContent).toContain("1 done · 1 failed");
    expect(ended.querySelectorAll(".acpmux-session-info-subagents__avatars > span")).toHaveLength(2);
    expect(ended.querySelector(`.${WAVE_CLASS}, [style*='--wave-index']`)).toBeNull();
  } finally {
    dom.window.close();
  }
});

test("the wave runs only with motion: Reduce Motion, the motion gate, static indicators and a hidden page stop it", () => {
  const css = readFileSync(path.resolve(import.meta.dir, "../src/ui/wave.css"), "utf8");
  const at = css.indexOf(`.${WAVE_CLASS} {`);
  expect(at).toBeGreaterThan(0);
  const media = css.lastIndexOf("@media", at);
  expect(css.slice(media, css.indexOf("{", media))).toContain("prefers-reduced-motion: no-preference");
  const selector = css.slice(css.indexOf("{", media) + 1, at).replace(/\s+/g, "");
  for (const gate of [
    ':not([data-cmux-motion="off"])',
    ':not([data-cmux-motion="reduced"])',
    ':not([data-status-indicators="static"])',
    ":not([data-cmux-page-hidden])",
  ])
    expect(selector).toContain(gate);
  const rule = css.slice(at, css.indexOf("}", at));
  expect(rule).toContain(`animation: ${WAVE_KEYFRAMES} var(--cmux-wave-period)`);
  expect(rule).toContain("var(--wave-index, 0) * var(--cmux-wave-step) - 20 * var(--cmux-wave-period)");
  expect(css).toContain("--cmux-wave-period: 1.6s;");
  // The keyframes change opacity only (compositor-only).
  const keyframes = css.indexOf(`@keyframes ${WAVE_KEYFRAMES}`);
  const frames = css.slice(keyframes, css.indexOf("@media", keyframes));
  expect(frames.match(/[a-z-]+(?=:)/g)).toEqual(["opacity", "opacity"]);
});

test("Session Info's wave sweeps slower than the shared one, period and step scaled together", () => {
  // Leo 2026-10-28: "I think it could maybe be a bit slower on the session info region".
  const shared = readFileSync(path.resolve(import.meta.dir, "../src/ui/wave.css"), "utf8");
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/session-info/SubagentsSection.css"),
    "utf8",
  );
  const at = css.indexOf(".acpmux-session-info-subagents {");
  expect(at).toBeGreaterThanOrEqual(0);
  const rule = css.slice(at, css.indexOf("}", at));
  const ms = (text: string, name: string) => {
    const match = text.match(new RegExp(`${name}:\\s*([\\d.]+)(m?s);`))!;
    return Number(match[1]) * (match[2] === "s" ? 1000 : 1);
  };
  const period = ms(rule, "--cmux-wave-period");
  expect(period).toBeGreaterThan(ms(shared, "--cmux-wave-period"));
  expect(period / ms(rule, "--cmux-wave-step")).toBeCloseTo(
    ms(shared, "--cmux-wave-period") / ms(shared, "--cmux-wave-step"),
    6,
  );
});
