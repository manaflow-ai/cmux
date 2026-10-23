// The context ring draws no pill in any state (#23785, Leo 2026-10-21: its card is the feedback):
// not under the pointer, not while its card is open, not while it is pressed (:active, or a touch
// press held by data-press-active, popoverTrigger.ts) and not under keyboard focus, where it
// keeps only the row's outline. Every other composer control is the same `.acpmux-pill` and does get
// the soft pill in those states (composerLocation.css), so a shared state rule can fill the ring by
// accident; ContextCard.test.tsx only reads rules that name the ring. This loads the real composer
// stylesheets in Chromium, with the shipped theme tokens (the pane's root tokens, a theme's text color
// and the .acpmux-shell scope that defines --acpmux-pill-hover), and reads the cascade's answer in
// the chat's bar, the quiet row under the box and the New Tab's pickers. A mode chip beside the ring
// must draw the shipped wash in the same state, so the check is not vacuous.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-ring-no-fill.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-ring-no-fill: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer ring no fill", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src/agent-session");
  const css = [
    "shared/styles.css",
    "acpmux/styles.css",
    "acpmux/composerLocation.css",
    "acpmux/composerControls.css",
    "acpmux/composerStates.css",
    "acpmux/contextCard.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  // Catppuccin Mocha's text, as the app sets it on the page (--cmux-text feeds --agent-text).
  const inShell = (markup: string) =>
    `<style>${css}</style><style>:root { --cmux-text: #cdd6f4; }</style>` +
    `<div class="acpmux-shell"><span id="wash" style="background: var(--acpmux-pill-hover)"></span>${markup}</div>`;
  const row = (classes: string, extra = "") =>
    `<div class="${classes}"${extra}><button id="before">Before</button>` +
    `<div class="acpmux-chips"><div class="acpmux-access"><button id="chip" class="acpmux-access-trigger acpmux-pill" aria-expanded="false">Auto</button></div></div>` +
    `<button id="ring" class="acpmux-context-ring acpmux-pill acpmux-pill-icon" aria-expanded="false" aria-label="42% of context used">◔</button></div>`;
  const ROWS = {
    bar: row("acpmux-composer-bar"),
    "quiet row": row("acpmux-composer-bar acpmux-composer-foot", ' data-footer-look="plain"'),
    "New Tab": row("nt-pickers"),
  };
  type State =
    | "pointer hover"
    | "keyboard focus"
    | "touch press"
    | "pointer press"
    | "open"
    | "open with keyboard focus";
  const STATES: State[] = [
    "pointer hover",
    "keyboard focus",
    "touch press",
    "pointer press",
    "open",
    "open with keyboard focus",
  ];

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  /** Puts #id into `state` and returns its computed background and whether the state took. */
  async function fillIn(page: Page, id: "ring" | "chip", state: State) {
    const target = `#${id}`;
    if (state.includes("open")) await page.locator(target).evaluate((el) => el.setAttribute("aria-expanded", "true"));
    if (state.includes("keyboard focus")) {
      await page.focus("#before");
      while (!(await page.locator(target).evaluate((el) => el === document.activeElement)))
        await page.keyboard.press("Tab");
    }
    if (state === "touch press") await page.locator(target).evaluate((el) => el.setAttribute("data-press-active", ""));
    if (state === "pointer hover" || state === "pointer press") {
      // Headless Chromium applies no :hover or :active from synthetic mouse input, so DevTools forces
      // the state; el.matches() does not see a forced state, and the chip's wash below shows it took.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("DOM.enable");
      await cdp.send("CSS.enable");
      const { root } = await cdp.send("DOM.getDocument");
      const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: target });
      await cdp.send("CSS.forcePseudoState", {
        nodeId,
        forcedPseudoClasses: [state === "pointer hover" ? "hover" : "active"],
      });
    }
    const result = await page.locator(target).evaluate((el, s) => {
      const held: Record<string, string> = {
        "pointer hover": "*",
        "keyboard focus": ":focus-visible",
        "open with keyboard focus": ":focus-visible",
        "pointer press": "*",
        "touch press": "[data-press-active]",
        open: '[aria-expanded="true"]',
      };
      const wash = getComputedStyle(document.getElementById("wash")!).backgroundColor;
      return { background: getComputedStyle(el).backgroundColor, held: el.matches(held[s]!), wash };
    }, state);
    return result;
  }

  const TRANSPARENT = /^(?:transparent|rgba\(.*,\s*0\))$/;

  for (const [name, markup] of Object.entries(ROWS)) {
    for (const state of STATES) {
      test(`${name}: the ring takes no fill under ${state}; a chip beside it does`, async () => {
        const page = await browser!.newPage();
        try {
          await page.setContent(inShell(markup));
          const ring = await fillIn(page, "ring", state);
          expect(ring.held).toBe(true);
          expect(ring.background).toMatch(TRANSPARENT);
          await page.setContent(inShell(markup));
          const chip = await fillIn(page, "chip", state);
          expect(chip.held).toBe(true);
          // The shipped wash is a real color from the theme's text, and the chip draws exactly it.
          expect(chip.wash).not.toMatch(TRANSPARENT);
          expect(chip.background).toBe(chip.wash);
        } finally {
          await page.close();
        }
      });
    }
  }
});
