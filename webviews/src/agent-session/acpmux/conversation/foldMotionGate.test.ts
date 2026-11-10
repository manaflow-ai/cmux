// The transcript's folds and their chevron read the app's motion gate as every other web motion does
// (ui/motion/motionMode.ts): `data-cmux-motion` off or reduced on the root folds at once and snaps the
// chevron, as `data-agent-motion="off"` already did. fold.ts read only the agent pane's own switch and
// the media query, which WebKit can answer "no-preference" under cmux's own Reduce Motion (theme.ts).
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { foldMotion, foldMs } from "./fold";

const scope = globalThis as Record<string, unknown>;
const saved = { document: scope.document, window: scope.window };
afterEach(() => Object.assign(scope, saved));

function body(motion?: string) {
  const dom = new JSDOM("<!doctype html><body><div class=cv-fold></div></body>");
  if (motion) dom.window.document.documentElement.dataset.cmuxMotion = motion;
  Object.assign(scope, { document: dom.window.document, window: dom.window });
  const node = dom.window.document.querySelector<HTMLElement>(".cv-fold")!;
  node.animate = (() => ({})) as never;
  return node;
}

test("a fold moves under the app's full motion and folds at once when its gate is off or reduced", () => {
  const reduced = foldMotion.reducedMotion;
  foldMotion.reducedMotion = () => false;
  try {
    expect(foldMs(body())).toBeGreaterThan(0);
    expect(foldMs(body("full"))).toBeGreaterThan(0);
    expect(foldMs(body("off"))).toBe(0);
    expect(foldMs(body("reduced"))).toBe(0);
  } finally {
    foldMotion.reducedMotion = reduced;
  }
});

test("the chevron snaps under the app's motion gate too", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  const rule = /(:root:is\([^)]*\)) \.cv-rotor \{\s*transition: none;/.exec(css)?.[1] ?? "";
  expect(rule).toContain('[data-cmux-motion="off"]');
  expect(rule).toContain('[data-cmux-motion="reduced"]');
});
