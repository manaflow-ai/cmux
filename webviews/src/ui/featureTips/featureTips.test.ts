// The feature tip rules (leo-workspace design/feature-tips.md), one test each, on the real
// scheduler with a test clock and a jsdom page.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createTipController, type ShownTip, type TipAnchor, type TipController } from "./controller";
import { firstSentence, highlightTip } from "./catalog";
import { TIP_IDLE_MS, TIP_MAX_LAUNCHES, TIP_SETTLE_MS, type FeatureTipEntry } from "./policy";
import { memoryTipHost, storageLaunchStore, type LaunchStore, type TipHost } from "./store";

const TIPS: FeatureTipEntry[] = [
  { id: "browser-tip", anchor: "agent.browser", title: "Agents drive the browser", body: "One sentence." },
  { id: "inspector-tip", anchor: "agent.inspector", title: "The Inspector", body: "One sentence." },
];
const ANCHORS: Record<string, TipAnchor> = {
  "agent.browser": { selector: "#browser", side: "bottom" },
  "agent.inspector": { selector: "#inspector", side: "bottom" },
};

let dom: JSDOM;
let clock: number;
let timers: { at: number; run: () => void }[];
let pages: TipController[];

beforeEach(() => {
  dom = new JSDOM(
    '<!doctype html><body><button id="browser"></button><button id="inspector"></button><input id="elsewhere"></body>',
    {
      url: "http://localhost/",
    },
  );
  for (const button of dom.window.document.querySelectorAll("button"))
    button.getBoundingClientRect = () => new dom.window.DOMRect(10, 10, 24, 24);
  clock = 0;
  timers = [];
  pages = [];
});

afterEach(() => {
  for (const page of pages) page.stop();
  dom.window.close();
});

/** Moves the test clock on, running each timer that comes due. */
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

interface PageOptions {
  host?: TipHost;
  launch?: LaunchStore;
  typing?: () => boolean;
  enabled?: boolean;
  tips?: FeatureTipEntry[];
}

async function page(options: PageOptions = {}) {
  const shown: (ShownTip | null)[] = [];
  const controller = createTipController({
    tips: options.tips ?? TIPS,
    anchors: ANCHORS,
    host: options.host ?? memoryTipHost(),
    launch: options.launch ?? storageLaunchStore(dom.window.localStorage, dom.window),
    doc: dom.window.document,
    typing: options.typing ?? (() => false),
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
  controller.update({ enabled: options.enabled ?? true, streaming: false });
  await controller.start();
  return { controller, shown };
}

const press = (selector: string, type = "pointerdown") =>
  dom.window.document.querySelector(selector)!.dispatchEvent(new dom.window.Event(type, { bubbles: true }));

/** A new launch: the pages' shared store starts empty again. */
const relaunch = () => dom.window.localStorage.clear();

describe("feature tips", () => {
  test("show at the first idle moment after the page settles, never on launch over work", async () => {
    const { controller } = await page();
    advance(TIP_SETTLE_MS - 1);
    expect(controller.shown).toBeNull();
    advance(1);
    expect(controller.shown?.tip.id).toBe("browser-tip");
  });

  test("wait for an idle moment: each key or press starts the wait again", async () => {
    const { controller } = await page();
    advance(TIP_SETTLE_MS - 2000);
    press("#elsewhere", "keydown");
    advance(TIP_IDLE_MS - 1);
    expect(controller.shown).toBeNull();
    advance(1);
    expect(controller.shown).not.toBeNull();
  });

  test("never while an agent is streaming, and a turn that starts puts one away", async () => {
    const { controller } = await page();
    controller.update({ enabled: true, streaming: true });
    advance(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    controller.update({ enabled: true, streaming: false });
    expect(controller.shown).not.toBeNull();
    controller.update({ enabled: true, streaming: true });
    expect(controller.shown).toBeNull();
  });

  test("never while the person is typing, and a key puts one away", async () => {
    let draft = true;
    const { controller } = await page({ typing: () => draft });
    advance(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    draft = false;
    press("#elsewhere", "keydown");
    advance(TIP_IDLE_MS);
    expect(controller.shown).not.toBeNull();
    press("#elsewhere", "keydown");
    expect(controller.shown).toBeNull();
  });

  test("one tip at a time, and one per launch across every page", async () => {
    const first = await page();
    const second = await page();
    advance(TIP_SETTLE_MS);
    expect([first.controller.shown, second.controller.shown].filter(Boolean)).toHaveLength(1);
    press("#elsewhere");
    advance(TIP_SETTLE_MS * 4);
    expect(first.controller.shown).toBeNull();
    expect(second.controller.shown).toBeNull();
    const third = await page();
    advance(TIP_SETTLE_MS * 4);
    expect(third.controller.shown).toBeNull();
  });

  test("its X closes it for good", async () => {
    const host = memoryTipHost();
    const { controller } = await page({ host, tips: [TIPS[0]!] });
    advance(TIP_SETTLE_MS);
    controller.close();
    expect(controller.shown).toBeNull();
    expect(host.records["browser-tip"]).toBe("closed");
    relaunch();
    const next = await page({ host, tips: [TIPS[0]!] });
    advance(TIP_SETTLE_MS * 4);
    expect(next.controller.shown).toBeNull();
  });

  test("using the feature closes it for good, shown or not", async () => {
    const host = memoryTipHost();
    const { controller } = await page({ host });
    press("#inspector", "click");
    expect(host.records["inspector-tip"]).toBe("used");
    advance(TIP_SETTLE_MS);
    expect(controller.shown?.tip.id).toBe("browser-tip");
    press("#browser");
    expect(controller.shown).not.toBeNull();
    press("#browser", "click");
    expect(controller.shown).toBeNull();
    expect(host.records["browser-tip"]).toBe("used");
    relaunch();
    const next = await page({ host });
    advance(TIP_SETTLE_MS * 4);
    expect(next.controller.shown).toBeNull();
  });

  test("the Settings toggle hides every tip", async () => {
    const off = await page({ enabled: false });
    advance(TIP_SETTLE_MS * 4);
    expect(off.controller.shown).toBeNull();
    off.controller.stop();
    const { controller } = await page();
    advance(TIP_SETTLE_MS);
    expect(controller.shown).not.toBeNull();
    controller.update({ enabled: false, streaming: false });
    expect(controller.shown).toBeNull();
  });

  test("no control on screen, no tip", async () => {
    dom.window.document.querySelector("#browser")!.remove();
    dom.window.document.querySelector("#inspector")!.getBoundingClientRect = () => new dom.window.DOMRect(0, 0, 0, 0);
    const { controller } = await page();
    advance(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
  });

  test("an app that keeps no records shows none", async () => {
    const host: TipHost = { read: () => Promise.reject(new Error("unsupported")), write: async () => undefined };
    const { controller } = await page({ host });
    advance(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
  });

  test(`a tip passed over on ${TIP_MAX_LAUNCHES} launches retires`, async () => {
    const host = memoryTipHost();
    for (let launch = 0; launch < TIP_MAX_LAUNCHES; launch++) {
      relaunch();
      const { controller } = await page({ host, tips: [TIPS[0]!] });
      advance(TIP_SETTLE_MS);
      expect(controller.shown).not.toBeNull();
      controller.stop();
    }
    expect(host.records["browser-tip"]).toBe(`shown:${TIP_MAX_LAUNCHES}`);
    relaunch();
    const last = await page({ host, tips: [TIPS[0]!] });
    advance(TIP_SETTLE_MS * 4);
    expect(last.controller.shown).toBeNull();
    expect(timers).toHaveLength(0);
  });
});

describe("tips from What's New highlights", () => {
  test("a highlight's tip: line makes its tip from its title and first sentence", () => {
    const text =
      "title: Agents drive the browser tabs you can see\ncategory: improved\ntip: agent.browser\n\nAgents now drive real tabs in your window. Background tabs take clicks.\n";
    expect(highlightTip("agents.md", text)).toEqual({
      id: "agents",
      anchor: "agent.browser",
      title: "Agents drive the browser tabs you can see",
      body: "Agents now drive real tabs in your window.",
    });
    expect(highlightTip("plain.md", "title: T\n\nBody.")).toBeNull();
    expect(() => highlightTip("fixed.md", "title: T\ncategory: fixed\ntip: agent.browser\n\nBody.")).toThrow();
    expect(firstSentence("Use cmux.app now. Then more.")).toBe("Use cmux.app now.");
  });

  test("tips.generated.json is the highlights' tips, and each names a control of the chat", async () => {
    const { generatedTips, GENERATED } = await import("../../../scripts/gen-feature-tips");
    const { readFileSync } = await import("node:fs");
    expect(readFileSync(GENERATED, "utf8")).toBe(generatedTips());
    const { PANE_TIP_ANCHORS } = await import("../../agent-session/acpmux/featureTips");
    for (const tip of JSON.parse(generatedTips()) as FeatureTipEntry[])
      expect(Object.keys(PANE_TIP_ANCHORS)).toContain(tip.anchor);
  });
});
