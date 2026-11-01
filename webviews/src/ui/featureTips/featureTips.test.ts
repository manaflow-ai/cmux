// The feature tip rules (leo-workspace design/feature-tips.md), one test each, on the real
// scheduler with a test clock and a jsdom page, and the app's install-level records in memory as the
// Swift AgentPaneFeatureTipRecords keeps them. Leo, 2026-10-30: "no this should be very very
// infrequent like app installation level frequent and if they havent used the browser".
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createTipController, pageOverlayOpen, type ShownTip, type TipAnchor, type TipController } from "./controller";
import { firstSentence, generatedTips, GENERATED, highlightTip } from "../../../scripts/pages/gen-feature-tips.mjs";
import { TIP_IDLE_MS, TIP_SETTLE_MS, type FeatureTipEntry } from "./policy";
import { memoryTipHost, TIP_INTERVAL_DAYS, type TipHost } from "./store";

const TIPS: FeatureTipEntry[] = [
  {
    id: "browser-tip",
    anchor: "agent.browser",
    title: "Agents drive the browser",
    body: "One sentence.",
    feature: "browser",
  },
  { id: "session-info-tip", anchor: "agent.inspector", title: "Session Info", body: "One sentence." },
];
const ANCHORS: Record<string, TipAnchor> = {
  "agent.browser": { selector: "#browser", side: "bottom", feature: "browser" },
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
  install = memoryTipHost();
  install.now = () => wall;
  wall = Date.UTC(2026, 9, 30);
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
  typing?: () => boolean;
  enabled?: boolean;
  tips?: FeatureTipEntry[];
  /** Look for open overlays in the page (default: none open). */
  overlays?: boolean;
}

async function page(options: PageOptions = {}) {
  const shown: (ShownTip | null)[] = [];
  const controller = createTipController({
    tips: options.tips ?? TIPS,
    anchors: ANCHORS,
    host: options.host ?? install,
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
    overlayOpen: options.overlays ? undefined : () => false,
  });
  pages.push(controller);
  controller.update({ enabled: options.enabled ?? true, streaming: false });
  await controller.start();
  return { controller, shown };
}

const press = (selector: string, type = "pointerdown") =>
  dom.window.document.querySelector(selector)!.dispatchEvent(new dom.window.Event(type, { bubbles: true }));

/** The app's records for this install, shared by every page and launch of a test. */
let install: ReturnType<typeof memoryTipHost>;
/** The app's wall clock, for the days between tips. */
let wall: number;
/** A relaunch: every page of the last launch is gone; the install's records stay. */
const relaunch = () => {
  for (const each of pages.splice(0)) each.stop();
};
/** Moves the clock on, then lets the app's answer to a claim arrive. */
async function settle(ms: number) {
  advance(ms);
  await Promise.resolve();
  await new Promise((done) => setTimeout(done, 0));
}

describe("feature tips", () => {
  test("show at the first idle moment after the page settles, never on launch over work", async () => {
    const { controller } = await page();
    await settle(TIP_SETTLE_MS - 1);
    expect(controller.shown).toBeNull();
    await settle(1);
    expect(controller.shown?.tip.id).toBe("browser-tip");
  });

  test("wait for an idle moment: each key or press starts the wait again", async () => {
    const { controller } = await page();
    await settle(TIP_SETTLE_MS - 2000);
    press("#elsewhere", "keydown");
    await settle(TIP_IDLE_MS - 1);
    expect(controller.shown).toBeNull();
    await settle(1);
    expect(controller.shown).not.toBeNull();
  });

  test("never while an agent is streaming, and a turn that starts puts one away", async () => {
    const { controller } = await page();
    controller.update({ enabled: true, streaming: true });
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    controller.update({ enabled: true, streaming: false });
    await settle(0);
    expect(controller.shown).not.toBeNull();
    controller.update({ enabled: true, streaming: true });
    expect(controller.shown).toBeNull();
  });

  test("never while the person is typing, and a key puts one away", async () => {
    let draft = true;
    const { controller } = await page({ typing: () => draft });
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    draft = false;
    press("#elsewhere", "keydown");
    await settle(TIP_IDLE_MS);
    expect(controller.shown).not.toBeNull();
    press("#elsewhere", "keydown");
    expect(controller.shown).toBeNull();
  });

  test("shown once per install: never again after a relaunch, even after it was only put away", async () => {
    const { controller } = await page();
    await settle(TIP_SETTLE_MS);
    expect(controller.shown?.tip.id).toBe("browser-tip");
    press("#elsewhere", "keydown");
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBe("shown");
    relaunch();
    wall += 365 * 86_400_000;
    const next = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS * 4);
    expect(next.controller.shown).toBeNull();
  });

  test("one tip at a time across pages, and at most one tip every 14 days", async () => {
    const first = await page();
    const second = await page();
    await settle(TIP_SETTLE_MS);
    expect([first.controller.shown, second.controller.shown].filter(Boolean)).toHaveLength(1);
    relaunch();
    wall += (TIP_INTERVAL_DAYS - 1) * 86_400_000;
    const soon = await page();
    await settle(TIP_SETTLE_MS * 4);
    expect(soon.controller.shown).toBeNull();
    relaunch();
    wall += 2 * 86_400_000;
    const later = await page();
    await settle(TIP_SETTLE_MS);
    expect(later.controller.shown?.tip.id).toBe("session-info-tip");
  });

  test("never when the browser was used, by any path the app saw", async () => {
    install.used.add("browser");
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBeUndefined();
  });

  test("an existing install with browser use sees nothing, and its page stops listening", async () => {
    install.used.add("browser");
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    expect(timers).toHaveLength(0);
  });

  test("browser use before the idle moment cancels the pending tip", async () => {
    const clicked = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS - 1000);
    press("#browser", "click");
    await settle(TIP_SETTLE_MS * 4);
    expect(clicked.controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBe("used");
  });

  test("an agent opening a browser tab before the idle moment cancels it too", async () => {
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS - 1000);
    install.used.add("browser");
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBeUndefined();
  });

  test("its X closes it for good", async () => {
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS);
    controller.close();
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBe("closed");
  });

  test("using the feature while the tip shows closes it for good", async () => {
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS);
    press("#browser");
    expect(controller.shown).not.toBeNull();
    press("#browser", "click");
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBe("used");
  });

  test("the Settings toggle hides every tip", async () => {
    const off = await page({ enabled: false });
    await settle(TIP_SETTLE_MS * 4);
    expect(off.controller.shown).toBeNull();
    off.controller.stop();
    const { controller } = await page();
    await settle(TIP_SETTLE_MS);
    expect(controller.shown).not.toBeNull();
    controller.update({ enabled: false, streaming: false });
    expect(controller.shown).toBeNull();
  });

  test("never over an open card, menu or dialog: an AnchoredCard opening in the idle wait holds it", async () => {
    const { controller } = await page({ tips: [TIPS[0]!], overlays: true });
    await settle(TIP_SETTLE_MS - 1000);
    const card = dom.window.document.createElement("div");
    card.className = "ui-tooltip ui-card ui-glass";
    card.setAttribute("role", "dialog");
    card.getBoundingClientRect = () => new dom.window.DOMRect(10, 40, 240, 80);
    dom.window.document.body.append(card);
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    expect(install.records["browser-tip"]).toBeUndefined();
    card.remove();
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
    press("#elsewhere", "keydown");
    await settle(TIP_IDLE_MS - 1);
    expect(controller.shown).toBeNull();
    await settle(1);
    expect(controller.shown?.tip.id).toBe("browser-tip");
  });

  test("the pages' hidden title tooltip never holds the tip back (a fresh install sees it)", async () => {
    const { installTooltips } = await import("../titleTooltips");
    const uninstall = installTooltips(dom.window.document);
    try {
      const { controller } = await page({ tips: [TIPS[0]!], overlays: true });
      await settle(TIP_SETTLE_MS);
      expect(controller.shown?.tip.id).toBe("browser-tip");
    } finally {
      uninstall();
    }
  });

  test("the overlay check sees every open surface, and never the tip itself", () => {
    const doc = dom.window.document;
    const kinds: [string, string][] = [
      ["div", 'role="menu"'],
      ["div", 'role="listbox"'],
      ["div", 'role="dialog"'],
      ["div", 'role="alertdialog"'],
      ["div", 'aria-modal="true"'],
      ["div", 'role="tooltip"'],
      ["div", 'class="ui-popup"'],
      ["div", 'class="ui-tooltip ui-card"'],
      ["div", 'class="acpmux-menu"'],
      ["dialog", "open"],
    ];
    for (const [tag, attribute] of kinds) {
      doc.body.insertAdjacentHTML("beforeend", `<${tag} id="overlay" ${attribute}></${tag}>`);
      doc.getElementById("overlay")!.getBoundingClientRect = () => new dom.window.DOMRect(10, 40, 240, 80);
      expect(`${tag} ${attribute}: ${pageOverlayOpen(doc)}`).toBe(`${tag} ${attribute}: true`);
      doc.getElementById("overlay")!.remove();
    }
    doc.body.insertAdjacentHTML("beforeend", '<div class="ui-popup" role="dialog" data-feature-tip=""></div>');
    doc.body.insertAdjacentHTML("beforeend", '<div class="ui-popup" role="menu" data-ending-style=""></div>');
    expect(pageOverlayOpen(doc)).toBe(false);
  });

  test("a control removed from the page puts its tip away", async () => {
    const { controller } = await page({ tips: [TIPS[0]!] });
    await settle(TIP_SETTLE_MS);
    expect(controller.shown).not.toBeNull();
    dom.window.document.querySelector("#browser")!.remove();
    dom.window.dispatchEvent(new dom.window.Event("focus"));
    expect(controller.shown).toBeNull();
  });

  test("no control on screen, no tip", async () => {
    dom.window.document.querySelector("#browser")!.remove();
    dom.window.document.querySelector("#inspector")!.getBoundingClientRect = () => new dom.window.DOMRect(0, 0, 0, 0);
    const { controller } = await page();
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
  });

  test("an app that keeps no records shows none", async () => {
    const refused = () => Promise.reject(new Error("unsupported"));
    const host: TipHost = { read: refused, write: refused, claim: refused };
    const { controller } = await page({ host });
    await settle(TIP_SETTLE_MS * 4);
    expect(controller.shown).toBeNull();
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

  test("tips.generated.json is made from this tree's highlights, and each tip names a control of the chat", async () => {
    const { readFileSync } = await import("node:fs");
    // test/preload.ts wrote it, as install and every build do (it is build output, ignored by git).
    expect(readFileSync(GENERATED, "utf8")).toBe(generatedTips());
    const tips = JSON.parse(generatedTips()) as FeatureTipEntry[];
    expect(tips.map((tip) => tip.id)).toContain("agents-drive-visible-browser-tabs");
    const { PANE_TIP_ANCHORS } = await import("../../agent-session/acpmux/featureTips");
    for (const tip of tips) expect(Object.keys(PANE_TIP_ANCHORS)).toContain(tip.anchor);
  });
});
