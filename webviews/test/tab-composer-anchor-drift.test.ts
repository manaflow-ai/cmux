// l10n-allow-file: test fixture prompts, not shipped UI.
// One drift check over the pane's composer and chat-header animations (ask cluster c-ccd0651272, Leo:
// "tab-open jank"; the scope: "run your 1px drift assertion over every tab and composer animation and
// post a table showing which drift"). Each case brings the real pane (support/papercutChat.ts: the
// stand-in acpmux and the pane's dev entry, real Chromium) to rest, starts the painted-frame recorder
// (support/firstFrameRects.ts, its anchors), runs one animation, lets its frames pass and reads how far
// each anchor that should hold still moved from its first frame: the composer's bottom edge, the Send
// slot, the caret's line, the picker rail, the header's tools. Under 1 px holds still.
//
// A case that drifts today is in DRIFTS with the px it measured: it runs as `test.failing`, so it
// reads red here if it stops drifting (then drop its entry) and is never a skip. No animation is fixed
// in this file. The Mac tab strip (open, close, select, reorder, closing-mode release, hover card) is
// AppKit and is not drawn here. Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/tab-composer-anchor-drift.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import {
  CARET_ANCHOR,
  type Edge,
  edgeDrift,
  paintedFor,
  startFirstFrameRects,
  stopFirstFrameRects,
} from "./support/firstFrameRects";
import { COMPOSER_MD, MAIN_DOCK, MODEL_PICKER, PLUS_PICKER } from "../src/agent-session/acpmux/composerSelectors";

/// The anchors, by the name the table gives them.
const ANCHORS = {
  "composer bottom edge": `${MAIN_DOCK} .acpmux-composer-box`,
  "composer box": `${MAIN_DOCK} .acpmux-composer-box`,
  "send slot": `${MAIN_DOCK} .acpmux-composer-actions`,
  "caret line": CARET_ANCHOR,
  "picker rail": ".acpmux-composer-box .acpmux-chips",
  "header tools": ".acpmux-header-tools",
  /// Movers, not anchors: proof the case's animation ran (the box's top grows or shrinks, a menu shows).
  "composer top edge": `${MAIN_DOCK} .acpmux-composer-box`,
  menu: ".ui-popup",
} as const;
type Anchor = keyof typeof ANCHORS;
/// The edges each anchor holds: the composer grows up from its bottom edge; the caret's line is its
/// bottom (typing moves it sideways by design); the rest hold every edge.
const EDGES: Partial<Record<Anchor, Edge[]>> = {
  "composer bottom edge": ["bottom"],
  "caret line": ["bottom"],
  "composer top edge": ["top"],
  menu: ["top"],
};

/// 1 px or more between frames, where it should hold still, is drift.
const DRIFT_PX = 1;
/// Every motion token ends inside this (the longest, the dock's, is under 400 ms).
const FRAMES_MS = 900;

type Case = {
  name: string;
  anchors: Anchor[];
  /// What the animation itself moves or shows, so a case that ran nothing cannot read as still:
  /// "moves" must move 1 px or more, "shows" must be drawn by the end.
  proof: { moves: Anchor } | { shows: Anchor };
  /// Brings the pane to the case's resting state (focused, a draft typed, a chip pasted).
  rest?: (page: Page) => Promise<void>;
  /// The one action whose animation is judged.
  act: (page: Page) => Promise<void>;
};

const DRAFT = "Check the retry policy";
const WRAP = " and say whether the client waits longer before each retry, with random jitter";
/// Past PASTE_CHIP_CHARS (pastedText.ts): the paste lands as a text attachment, not in the field.
const LONG_PASTE = Array.from({ length: 900 }, (_, n) => `Line ${n + 1} of the pasted notes`).join("\n");

/// A trigger the stand-in chat does not draw fails its case in seconds, naming it.
const TRIGGER_MS = 10_000;
const focusField = (page: Page) => page.locator(COMPOSER_MD).first().click({ timeout: TRIGGER_MS });
const paste = (page: Page, text: string) =>
  page.evaluate(
    ({ selector, text }) => {
      const field = document.querySelector<HTMLElement>(selector)!;
      const data = new DataTransfer();
      data.setData("text/plain", text);
      field.dispatchEvent(
        new ClipboardEvent("paste", {
          clipboardData: data,
          bubbles: true,
          cancelable: true,
        }),
      );
    },
    { selector: COMPOSER_MD, text },
  );

const CASES: Case[] = [
  {
    name: "composer grow (a new line)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "caret line", "picker rail", "header tools"],
    rest: async (page) => {
      await focusField(page);
      await page.keyboard.type(DRAFT);
    },
    act: (page) => page.keyboard.press("Shift+Enter"),
  },
  {
    name: "composer grow (typing wraps onto a second line)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "picker rail", "header tools"],
    rest: async (page) => {
      await focusField(page);
      await page.keyboard.type(DRAFT);
    },
    act: (page) => page.keyboard.type(WRAP),
  },
  {
    name: "composer shrink (the new line deleted)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "caret line", "picker rail", "header tools"],
    rest: async (page) => {
      await focusField(page);
      await page.keyboard.type(DRAFT);
      await page.keyboard.press("Shift+Enter");
    },
    act: (page) => page.keyboard.press("Backspace"),
  },
  {
    name: "send (Return on a two-line draft)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "picker rail", "header tools"],
    rest: async (page) => {
      await focusField(page);
      await page.keyboard.type(DRAFT);
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("and the jitter");
    },
    act: (page) => page.keyboard.press("Enter"),
  },
  {
    name: "attachment add (a long paste lands as a chip)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "picker rail", "header tools"],
    rest: focusField,
    act: (page) => paste(page, LONG_PASTE),
  },
  {
    name: "attachment remove (the chip's ×)",
    proof: { moves: "composer top edge" },
    anchors: ["composer bottom edge", "send slot", "picker rail", "header tools"],
    rest: async (page) => {
      await focusField(page);
      await paste(page, LONG_PASTE);
      await page
        .locator(`${MAIN_DOCK} :is(.acpmux-attachment-remove, .acpmux-md-inline-remove)`)
        .first()
        .waitFor({ timeout: TRIGGER_MS });
    },
    act: async (page) => {
      const remove = page.locator(`${MAIN_DOCK} :is(.acpmux-attachment-remove, .acpmux-md-inline-remove)`).first();
      // The × shows on hover: the pointer goes there first, at rest, so only the press is judged.
      await remove.click({ trial: true, timeout: TRIGGER_MS });
      await remove.click({ timeout: TRIGGER_MS });
    },
  },
  {
    name: "model menu opening",
    proof: { shows: "menu" },
    anchors: ["composer box", "send slot", "picker rail", "header tools"],
    act: (page) => page.locator(`${MAIN_DOCK} ${MODEL_PICKER}`).first().click({ timeout: TRIGGER_MS }),
  },
  {
    name: "mode menu opening",
    proof: { shows: "menu" },
    anchors: ["composer box", "send slot", "picker rail", "header tools"],
    act: (page) =>
      page.locator(`${MAIN_DOCK} .acpmux-picker-button:has(.acpmux-mode-text)`).first().click({ timeout: TRIGGER_MS }),
  },
  {
    name: "+ menu opening",
    proof: { shows: "menu" },
    anchors: ["composer box", "send slot", "picker rail", "header tools"],
    act: (page) => page.locator(`${MAIN_DOCK} ${PLUS_PICKER}`).first().click({ timeout: TRIGGER_MS }),
  },
];

/// The cases that drift today, with the most px measured (the run of 2026-11-24 on a lane VM's
/// Chromium) and the anchor. Each runs as test.failing until the animation is fixed.
const DRIFTS: Record<string, string> = {};

await requireBrowserLane("tab-composer-anchor-drift.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  const rows: string[] = [];
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 4, running: false });
  });
  afterAll(async () => {
    console.log(
      [
        "anchor-drift table:",
        "| animation | element | role | max drift px | rest offset px | frames |",
        "|---|---|---|---|---|---|",
        ...rows,
      ].join("\n"),
    );
    await pane?.close();
    await browser?.close();
  });

  for (const scenario of CASES) {
    const run = DRIFTS[scenario.name] ? test.failing : test;
    run(`${scenario.name}: what should hold still moves under ${DRIFT_PX} px`, async () => {
      const page = await pane.open({ width: 900, height: 700 });
      try {
        await scenario.rest?.(page);
        await paintedFor(page, 600);
        const proofAnchor = "moves" in scenario.proof ? scenario.proof.moves : scenario.proof.shows;
        const judged = [...scenario.anchors, proofAnchor];
        const anchors = Object.fromEntries(judged.map((anchor) => [anchor, ANCHORS[anchor]]));
        await startFirstFrameRects(page, "", "", anchors);
        await paintedFor(page, 100);
        await scenario.act(page);
        await paintedFor(page, FRAMES_MS);
        const report = await stopFirstFrameRects(page);
        const drift = edgeDrift(report, anchors, EDGES);
        for (const anchor of judged) {
          const measured = drift[anchor];
          const px =
            measured === undefined ? "not drawn" : `${measured.px}${measured.edge ? ` (${measured.edge})` : ""}`;
          const end = measured === undefined ? "" : `${measured.end}`;
          const role = anchor === proofAnchor ? "proof" : "anchor";
          rows.push(`| ${scenario.name} | ${anchor} | ${role} | ${px} | ${end} | ${report.frames} |`);
        }
        console.log(`anchor-drift ${scenario.name}: ${JSON.stringify({ frames: report.frames, drift })}`);
        const proof = drift[proofAnchor];
        const problems = [
          ...("moves" in scenario.proof
            ? proof && proof.px >= DRIFT_PX
              ? []
              : [`the animation did not run: ${proofAnchor} moved ${proof?.px ?? "(not drawn)"} px`]
            : proof
              ? []
              : [`the animation did not run: no ${proofAnchor} was drawn`]),
          ...scenario.anchors.flatMap((anchor) => {
            const measured = drift[anchor];
            if (measured === undefined) return [`${anchor} was not drawn, so nothing measured it`];
            return measured.px >= DRIFT_PX
              ? [`${anchor} moved ${measured.px} px (${measured.edge}), resting ${measured.end} px off`]
              : [];
          }),
        ];
        expect(problems).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
