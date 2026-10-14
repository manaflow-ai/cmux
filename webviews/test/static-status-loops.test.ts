// Leo 2026-10-13 (cx-sya4n): Austin gets headaches from blinking and pulsing lights. The native
// Static status indicators setting (or macOS Reduce Motion) reaches the agent pane as
// `data-status-indicators="static"` on the root (applyAgentTheme), and under it, or under Reduce
// Motion, no web loop may run: the mic's wait pulse, the model picker and harness spinners, the
// floating chat's breathing dot, the Thinking sweep, the reply caret's wait pulse, the Jump to
// Latest dots and Home's "writing" pulse. The diff viewer does not get the pane's theme, so its
// spinners stop under Reduce Motion alone. Static also gives the color-only marks a shape each.
// This loads the real stylesheets in Chromium and lists the animations that never end.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("static-status-loops.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("static-status-loops: skipping (run `bunx playwright install chromium`)");
    describe.skip("static status loops", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const desktop = css("pages/shared/desktop.css");
  const pane = [
    "agent-session/acpmux/composerStates.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/harnesses/harnesses.css",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/summary/summary.css",
  ]
    .map(css)
    .join("\n");
  const home = css("pages/home-channels/styles.css");
  const diff = css("styles.css");

  const paneLoops =
    `<button class="acpmux-mic" data-state="starting">mic</button>` +
    `<span class="acpmux-mp-refresh-spinner"></span><span class="acpmux-harness-spinner"></span>` +
    `<span class="acpmux-floating-status" data-status="streaming"></span>` +
    `<div class="cv-md"><span class="cv-thinking">Thinking</span></div>` +
    `<div class="cv-md is-waiting"><span class="cv-caret"></span></div>` +
    `<button class="acpmux-jump-latest" data-shown><span class="acpmux-jump-latest__dots"><i></i><i></i><i></i></span></button>` +
    `<span class="hc-writing">writing</span>`;
  const diffLoops = `<span class="base-picker-spinner"></span><div id="status" data-pending="true">Loading</div>`;

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function page(
    style: string,
    body: string,
    reducedMotion: "reduce" | "no-preference",
    look?: "static",
  ): Promise<Page> {
    const p = await browser!.newPage();
    await p.emulateMedia({ reducedMotion });
    await p.setContent(`<style>${style}</style>${body}`);
    if (look) await p.evaluate((value) => (document.documentElement.dataset.statusIndicators = value), look);
    // Let a changed rule take effect before reading the running animations.
    await p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    return p;
  }

  /** Every animation that repeats forever and is running, by the element it runs on. */
  async function loops(p: Page): Promise<string[]> {
    return p.evaluate(() =>
      document
        .getAnimations()
        .filter(
          (animation) => animation.effect?.getTiming().iterations === Infinity && animation.playState === "running",
        )
        .map((animation) => {
          const effect = animation.effect as KeyframeEffect | null;
          const target = effect?.target as Element | null;
          const name = (animation as CSSAnimation).animationName ?? "?";
          return `${target?.className || target?.id || target?.tagName} ${effect?.pseudoElement ?? ""} ${name}`.trim();
        }),
    );
  }

  test("the loops run by default (the check sees them)", async () => {
    const p = await page(`${desktop}${pane}${home}${diff}`, paneLoops + diffLoops, "no-preference");
    const running = await loops(p);
    await p.close();
    expect(running.length).toBeGreaterThanOrEqual(10);
  });

  test("Static status indicators stop every pane loop", async () => {
    const p = await page(`${desktop}${pane}${home}`, paneLoops, "no-preference", "static");
    const running = await loops(p);
    await p.close();
    expect(running).toEqual([]);
  });

  test("Reduce Motion stops every loop, the diff viewer's too", async () => {
    const p = await page(`${desktop}${pane}${home}${diff}`, paneLoops + diffLoops, "reduce");
    const running = await loops(p);
    await p.close();
    expect(running).toEqual([]);
  });

  test("the diff base picker's spinner stops under Reduce Motion by its own rule", async () => {
    const p = await page(diff, diffLoops, "reduce");
    const running = await loops(p);
    await p.close();
    expect(running).toEqual([]);
  });

  test("Static keeps Thinking readable: muted text, no sweep band", async () => {
    const p = await page(
      `${desktop}${pane}`,
      `<div class="cv-md"><span class="cv-thinking">Thinking</span></div>`,
      "no-preference",
      "static",
    );
    const thinking = await p.$eval(".cv-thinking", (node) => {
      const style = getComputedStyle(node);
      return { color: style.color, clip: style.backgroundClip, image: style.backgroundImage };
    });
    await p.close();
    expect(thinking.color).not.toBe("rgba(0, 0, 0, 0)");
    expect(thinking.clip).not.toBe("text");
    expect(thinking.image).toBe("none");
  });

  test("Static gives each color-only status mark its own shape", async () => {
    const body =
      `<span class="acpmux-floating-status" data-status="streaming"></span>` +
      `<span class="acpmux-floating-status" data-status="attention"></span>` +
      ["running", "done", "failed"]
        .map((state) => `<span class="acpmux-summary-dot" data-state="${state}"></span>`)
        .join("") +
      ["running", "waiting", "completed", "failed", "cancelled"]
        .map((state) => `<span class="acpmux-lineage__icon" data-state="${state}"></span>`)
        .join("");
    // The theme the pane always gets (applyAgentTheme), so state colors resolve as in the app.
    const colors =
      ":root{--agent-accent:#0a84ff;--agent-muted:#8e8e93;--agent-warning:#ff9f0a;--agent-danger:#ff453a;--surface-popup:#fff}";
    const p = await page(`${desktop}${pane}${colors}`, body, "no-preference", "static");
    const shapes = await p.evaluate(() => {
      const shape = (node: Element, pseudo?: string) => {
        const style = getComputedStyle(node, pseudo);
        return [
          style.content,
          style.clipPath,
          style.borderRadius,
          style.boxShadow.includes("inset") ? "ring" : "",
          style.backgroundColor === "rgba(0, 0, 0, 0)" ? "hollow" : "filled",
        ].join(" | ");
      };
      return {
        floating: [...document.querySelectorAll(".acpmux-floating-status")].map((node) => shape(node)),
        summary: [...document.querySelectorAll(".acpmux-summary-dot")].map((node) => shape(node, "::after")),
        lineage: [...document.querySelectorAll(".acpmux-lineage__icon")].map((node) => shape(node, "::after")),
      };
    });
    await p.close();
    expect(new Set(shapes.floating).size).toBe(2);
    expect(new Set(shapes.summary).size).toBe(3);
    expect(new Set(shapes.lineage).size).toBe(5);
  });
});
