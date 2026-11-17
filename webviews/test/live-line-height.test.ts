// The running turn's live line has ONE height, in every state, read from one place. Lucas's #41213 drew it 22
// tall under a run and 32 under a reply, so it moved each time the row over it changed between the two (cmux#24569,
// a live CLS of 1.16). Leo, 2026-11-16: "idk this seems like kind of a correctness thing tho we need to decide do
// we want 22 or 32 and centralize it so this doesnt happen". 32, the reply footer's slot it swaps with
// (cmux#43627): transcriptGrid.ts TRANSCRIPT_LIVE_LINE for the row estimates, conversation.css --cv-live-line for
// the drawn rows. This holds every live-line rule to that one value, so no second height comes back.
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";
import {
  MARK_LIVE_STEP,
  MARK_STEP,
  TRANSCRIPT_FOOTER_CONTROL,
  TRANSCRIPT_LIVE_LINE,
  TRANSCRIPT_LIVE_LINE_GAP,
  transcriptGap,
} from "../src/agent-session/acpmux/transcriptGrid";

const src = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const css = readFileSync(path.join(src, "conversation/conversation.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const model = readFileSync(path.join(src, "model.ts"), "utf8");

// A selector that draws the running turn's live line as its last row (Thinking.tsx / WorkingFor.tsx `is-below`,
// VirtualTranscript.tsx `acpmux-row--below` on an activity line).
const LIVE = /\.cv-worked\.is-below|\.acpmux-activityLine\.acpmux-row--below/;
const HEIGHT = /(?:^|[;{\s])((?:min-|max-)?height)\s*:\s*([^;}]+)/g;

function liveRules(): { selector: string; prop: string; value: string }[] {
  const out: { selector: string; prop: string; value: string }[] = [];
  for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selector = match[1].trim();
    if (!LIVE.test(selector)) continue;
    for (const decl of match[2].matchAll(HEIGHT)) out.push({ selector, prop: decl[1], value: decl[2].trim() });
  }
  return out;
}

describe("the live line's one height", () => {
  test("is the reply footer's 32 slot", () => {
    expect(TRANSCRIPT_LIVE_LINE).toBe(32);
    expect(TRANSCRIPT_LIVE_LINE).toBe(TRANSCRIPT_FOOTER_CONTROL);
    expect(css).toMatch(/--cv-live-line:\s*var\(--cv-footer-row\)/);
  });

  test("keeps Lucas's 16 gap over it under a run", () => {
    expect(TRANSCRIPT_LIVE_LINE_GAP).toBe(16);
    expect(transcriptGap(MARK_STEP, MARK_LIVE_STEP)).toBe(TRANSCRIPT_LIVE_LINE_GAP);
  });

  test("every live-line rule that sets a height reads --cv-live-line", () => {
    const rules = liveRules();
    expect(rules.length).toBeGreaterThan(0);
    const stray = rules.filter((rule) => rule.value !== "0" && rule.value !== "var(--cv-live-line)");
    expect(stray).toEqual([]);
  });

  test("no live-line rule under a step draws a second height", () => {
    const afterStep = liveRules().filter((rule) => rule.selector.includes("acpmux-row--after-step"));
    expect(afterStep).toEqual([]);
  });

  test("the row estimates read TRANSCRIPT_LIVE_LINE through liveLineRow", () => {
    expect(model).toMatch(/const liveLineRow = \(\) => TRANSCRIPT_LIVE_LINE \* chromeScale;/);
    expect(model).toMatch(/row\.below\) return finish\(liveLineRow\(\)\)/);
    expect(model).toMatch(/row\.below \? liveLineRow\(\) : metaRow\(\)/);
    expect(model).toMatch(/edge === LIVE_STEP_EDGE\s*\?\s*liveLineRow\(\)/);
  });
});
