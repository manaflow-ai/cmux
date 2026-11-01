// CSS-only transcript fixture: exercise the shipped selectors under coarse/fine pointers.
// Run on the fleet: bun scripts/agent-pane/capture-transcript-hover.mjs BEFORE_CSS OUT_DIR
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const current = new URL("../../src/agent-session/acpmux/conversation/conversation.css", import.meta.url);
const before = fs.readFileSync(process.argv[2], "utf8");
const after = fs.readFileSync(current, "utf8");
const out = process.argv[3];
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
try {
  for (const [version, css] of [
    ["before", before],
    ["after", after],
  ]) {
    for (const coarse of [true, false]) {
      const context = await browser.newContext({ viewport: { width: 640, height: 280 }, hasTouch: coarse });
      const page = await context.newPage();
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.setContent(`<style>${css}</style><style>
        :root { --agent-text:#ddd; --agent-muted:#aaa; --agent-soft:#999; --font-ui:system-ui; }
        body { margin:24px; background:#222; color:var(--agent-text); font:14px system-ui; }
        section { margin-block:20px; }
        button { color:inherit; background:transparent; border:0; }
      </style>
      <section class="cv-user"><div>Summarize the changes.</div><div class="cv-user__actions"><button>Copy</button><button>Edit</button></div></section>
      <section class="cv-received"><div>Checked the updated styles.</div><div class="cv-received-actions"><button>Copy</button><button>More</button></div></section>
      <section class="acpmux-turnSummary" tabindex="0"><span>Worked for 2s</span><div class="cv-turn-actions"><button>Copy</button><button>Retry</button></div></section>`);
      assert.equal(await page.evaluate(() => matchMedia("(pointer: coarse)").matches), coarse);
      assert.equal(await page.evaluate(() => matchMedia("(hover: hover)").matches), !coarse);
      // A touch tap can retain :hover. Force precisely that browser pseudo-state without
      // changing the CSS, then freeze any transition at its first frame for a stable capture.
      const cdp = await context.newCDPSession(page);
      await cdp.send("DOM.enable");
      await cdp.send("CSS.enable");
      const { root } = await cdp.send("DOM.getDocument");
      const hoveredNodes = [];
      for (const selector of [".cv-user", ".cv-received", ".acpmux-turnSummary"]) {
        const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector });
        hoveredNodes.push(nodeId);
        await cdp.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: ["hover"] });
      }
      const state = await page.evaluate(async () => {
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return [...document.querySelectorAll(".cv-user__actions,.cv-received-actions,.cv-turn-actions")].map((el) => {
          for (const animation of el.getAnimations()) {
            animation.pause();
            animation.currentTime = 0;
          }
          const s = getComputedStyle(el);
          return { opacity: s.opacity, duration: s.transitionDuration, delay: s.transitionDelay };
        });
      });
      for (const action of state) {
        assert.equal(action.duration, version === "after" && coarse ? "0s" : "0.12s");
        assert.equal(action.delay, version === "after" && coarse ? "0s" : "0.1s");
        if (version === "after" && coarse) assert.equal(action.opacity, "1");
      }
      if (coarse) await page.screenshot({ path: path.join(out, `${version}-coarse.png`), animations: "allow" });
      console.log(JSON.stringify({ version, coarse, state }));
      // Keyboard access is a separate interaction: clear the forced pointer state first.
      for (const nodeId of hoveredNodes) {
        await cdp.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: [] });
      }
      await page.locator(".cv-user__actions button").first().focus();
      assert.equal(
        await page.locator(".cv-user__actions").evaluate((el) => getComputedStyle(el).transitionDelay),
        "0s",
      );
      await page.emulateMedia({ reducedMotion: "reduce" });
      assert.equal(
        await page.locator(".cv-turn-actions").evaluate((el) => getComputedStyle(el).transitionDuration),
        "0s",
      );
      await context.close();
    }
  }
} finally {
  await browser.close();
}
