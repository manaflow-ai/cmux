// Moment tips (momentTipsModel.ts): off by default, pointed at controls the pane really draws, shown
// only once their situation is on screen, and inside the one install-wide tip budget.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { renderToString } from "react-dom/server";
import { createTipController, type ShownTip, type TipController } from "../../ui/featureTips/controller";
import { TIP_IDLE_MS, TIP_SETTLE_MS } from "../../ui/featureTips/policy";
import { memoryTipHost, TIP_INTERVAL_DAYS } from "../../ui/featureTips/store";
import { experimentArm } from "../../experiments/experiment";
import { PlanBuildSplit } from "./PermissionCard";
import { PaneMomentTips } from "./momentTips";
import { momentTipsExperiment } from "./momentTips.experiment";
import { MOMENT_TIP_ANCHORS, momentStreaming, momentTips } from "./momentTipsModel";
import type { Translate } from "./i18n";

const strings = (key: string) =>
  JSON.parse(readFileSync(join(import.meta.dir, "Localizable.xcstrings.d", `${key}.xcstrings`), "utf8")).strings[key]
    .localizations as Record<string, { stringUnit: { value: string } }>;
const english = (key: string) => strings(key).en!.stringUnit.value;
const TIPS = momentTips(english as Translate);

let dom: JSDOM;
let clock: number;
let timers: { at: number; run: () => void }[];
let pages: TipController[];
let install: ReturnType<typeof memoryTipHost>;
let wall: number;

beforeEach(() => {
  dom = new JSDOM('<!doctype html><body><main id="chat"></main></body>', { url: "http://localhost/" });
  clock = 0;
  timers = [];
  pages = [];
  install = memoryTipHost();
  wall = Date.UTC(2026, 10, 28);
  install.now = () => wall;
});

afterEach(() => {
  for (const page of pages) page.stop();
  dom.window.close();
});

function advance(ms: number) {
  const end = clock + ms;
  for (;;) {
    timers.sort((a, b) => a.at - b.at);
    const next = timers[0];
    if (!next || next.at > end) break;
    timers.shift();
    clock = next.at;
    next.run();
  }
  clock = end;
}

async function settle(ms: number) {
  advance(ms);
  await Promise.resolve();
  await new Promise((done) => setTimeout(done, 0));
}

async function page() {
  const shown: (ShownTip | null)[] = [];
  const controller = createTipController({
    tips: TIPS,
    anchors: MOMENT_TIP_ANCHORS,
    host: install,
    doc: dom.window.document,
    typing: () => false,
    onChange: (tip) => shown.push(tip),
    now: () => clock,
    setTimer: (run, ms) => {
      const timer = { at: clock + ms, run };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer) => {
      timers = timers.filter((entry) => entry !== timer);
    },
    focused: () => true,
    overlayOpen: () => false,
  });
  pages.push(controller);
  controller.update({ enabled: true, streaming: false });
  await controller.start();
  return { controller, shown };
}

/** Draws markup into the chat, every control sized as on screen. */
function draw(html: string) {
  const chat = dom.window.document.getElementById("chat")!;
  chat.innerHTML = html;
  for (const element of chat.querySelectorAll("*"))
    element.getBoundingClientRect = () => new dom.window.DOMRect(10, 10, 24, 24);
}

const PLAN_CARD = renderToString(
  <PlanBuildSplit harness="claude" onHere={() => undefined} onBuild={() => undefined}>
    <button type="button">Approve plan</button>
  </PlanBuildSplit>,
);
const JUMP_PILL =
  '<fieldset class="ui-glass acpmux-since-jump" data-shown=""><button type="button" class="acpmux-since-jump__body">3 new</button></fieldset>';

/** The person presses a key elsewhere: the scheduler looks again. */
const key = () => dom.window.document.dispatchEvent(new dom.window.Event("keydown", { bubbles: true }));

describe("moment tips", () => {
  test("off by default", () => {
    expect(momentTipsExperiment.defaultArm).toBe("off");
    expect(experimentArm(momentTipsExperiment)).toBe("off");
    expect(renderToString(<PaneMomentTips turnWorking={false} waitingOnPerson={false} />)).toBe("");
  });

  test("each points at a control the pane draws", () => {
    draw(PLAN_CARD);
    expect(dom.window.document.querySelector(MOMENT_TIP_ANCHORS["agent.planBuild"]!.selector)).not.toBeNull();
    // The pill's markup, as SinceDivider.tsx draws it; inert and unmarked while hidden.
    const divider = readFileSync(join(import.meta.dir, "conversation", "SinceDivider.tsx"), "utf8");
    for (const part of [
      'className="ui-glass acpmux-since-jump"',
      "data-shown={shown",
      'className="acpmux-since-jump__body"',
    ])
      expect(divider).toContain(part);
    draw(JUMP_PILL);
    expect(dom.window.document.querySelector(MOMENT_TIP_ANCHORS["agent.sinceJump"]!.selector)).not.toBeNull();
    draw(JUMP_PILL.replace(' data-shown=""', ""));
    expect(dom.window.document.querySelector(MOMENT_TIP_ANCHORS["agent.sinceJump"]!.selector)).toBeNull();
  });

  test("nothing until the situation is on screen, then the one tip", async () => {
    const { shown } = await page();
    await settle(TIP_SETTLE_MS + TIP_IDLE_MS + 60_000);
    expect(shown).toEqual([]);
    draw(PLAN_CARD);
    key();
    await settle(TIP_IDLE_MS);
    expect(shown.at(-1)?.tip.id).toBe("moment-plan-compare");
    expect(install.records["moment-plan-compare"]).toBe("shown");
  });

  test("never repeated, and the next waits out the shared 14 days", async () => {
    draw(PLAN_CARD);
    const first = await page();
    await settle(TIP_SETTLE_MS + TIP_IDLE_MS);
    expect(first.shown.at(-1)?.tip.id).toBe("moment-plan-compare");
    for (const each of pages.splice(0)) each.stop();

    wall += 2 * 86_400_000;
    draw(PLAN_CARD + JUMP_PILL);
    const soon = await page();
    await settle(TIP_SETTLE_MS + TIP_IDLE_MS);
    expect(soon.shown).toEqual([]);
    for (const each of pages.splice(0)) each.stop();

    wall += TIP_INTERVAL_DAYS * 86_400_000;
    const later = await page();
    await settle(TIP_SETTLE_MS + TIP_IDLE_MS);
    expect(later.shown.at(-1)?.tip.id).toBe("moment-away-jump");
  });

  test("a waiting plan card is the moment; a running turn is not", () => {
    expect(momentStreaming(true, true)).toBe(false);
    expect(momentStreaming(true, false)).toBe(true);
    expect(momentStreaming(false, false)).toBe(false);
  });

  test("short, and in every language the pane speaks", () => {
    const locales = Object.keys(strings("featureTip.new")).sort();
    for (const key of [
      "momentTip.planCompare.title",
      "momentTip.planCompare.body",
      "momentTip.awayJump.title",
      "momentTip.awayJump.body",
    ]) {
      expect(Object.keys(strings(key)).sort()).toEqual(locales);
      expect(english(key).split(/\s+/).length).toBeLessThanOrEqual(12);
    }
  });
});
