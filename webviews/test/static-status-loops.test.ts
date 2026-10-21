// Leo 2026-10-13 (cx-sya4n): blinking and pulsing lights give a teammate headaches. The native
// Static status indicators setting (or macOS Reduce Motion) reaches every page as
// `data-status-indicators="static"` on the root: the app's WebTheme bootstrap sets it from the theme
// payload (`statusIndicators`), which this test runs as the app does, and under it, or under Reduce
// Motion, no web loop may run: the mic's wait pulse, the model picker and harness spinners, the
// floating chat's breathing dot, the Thinking sweep, the todo list's spinner, the Jump to Latest
// dots and Home's "writing" pulse.
// The diff viewer does not get the pane's theme, so its spinners stop under Reduce Motion alone.
// Static also gives the color-only marks a shape each.
// This loads the real stylesheets in Chromium and lists the animations that never end.
import { readdirSync, readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";
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
  // The script the app installs at document start in every cmux web view (WebTheme.swift).
  const bootstrap = readWebThemeBootstrap();

  // A running transcript row's working mark (Spinner, WORKING-LOOK) with its words.
  const working =
    `<div class="cv-tool"><span class="cv-tool__icon"><span class="cv-spinner" data-working>` +
    `<span class="cv-spinner__arc"></span><span class="cv-spinner__dot"></span></span></span>` +
    `<span class="cv-tool__text">Compacting</span></div>`;
  const paneLoops =
    `<button class="acpmux-mic" data-state="starting">mic</button>` +
    `<span class="acpmux-mp-refresh-spinner"></span><span class="acpmux-harness-spinner"></span>` +
    `<span class="acpmux-floating-status" data-status="streaming"></span>` +
    `<div class="cv-md"><span class="cv-thinking">Thinking</span></div>` +
    `<button class="acpmux-jump-latest" data-shown data-working><span class="acpmux-jump-latest__dots"><i></i><i></i><i></i></span></button>` +
    `<ul class="cv-plan"><li class="cv-plan__item" data-status="in_progress"><span class="cv-plan__mark"></span></li></ul>` +
    `<span class="cv-spinner"></span>` +
    working +
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
    look?: "static" | "animated",
  ): Promise<Page> {
    const p = await browser!.newPage();
    await p.emulateMedia({ reducedMotion });
    await p.setContent(`<style>${style}</style>${body}`);
    if (look) {
      // The app's path: the bootstrap, then a theme push carrying the look (WebTheme.payloadJSON).
      await p.addScriptTag({ content: bootstrap });
      await p.evaluate(
        (value) =>
          (window as unknown as { cmuxTheme: { apply(payload: object): void } }).cmuxTheme.apply({
            variables: {},
            colorScheme: "light",
            statusIndicators: value,
          }),
        look,
      );
    }
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
    // The todo list's spinner among them, so the Static and Reduce Motion checks cover it.
    expect(running.some((loop) => loop.startsWith("cv-plan__mark") && loop.endsWith("cmux-spin"))).toBe(true);
    // The running rows' spinner (compaction, tool runs) too: it once had no rule and never turned.
    expect(running.some((loop) => loop.startsWith("cv-spinner") && loop.endsWith("cmux-spin"))).toBe(true);
    // Agent work turns as the spinner by default (WORKING-LOOK): the loading and the working ring both
    // spin, and the working dot runs no loop at all.
    expect(
      running.filter((loop) => loop.replace(/\s+/g, " ") === "cv-spinner cmux-spin").length,
    ).toBeGreaterThanOrEqual(2);
    expect(running.some((loop) => loop.startsWith("cv-spinner__dot"))).toBe(false);
  });

  /** The infinite running animations on a working mark (`.cv-spinner[data-working]` and what is in
   * it), each with ` opacity` when its keyframes animate opacity (a breath, a pulse, a blink). */
  async function workingMarkLoops(p: Page): Promise<string[]> {
    return p.evaluate(() =>
      document
        .getAnimations()
        .filter(
          (animation) => animation.effect?.getTiming().iterations === Infinity && animation.playState === "running",
        )
        .flatMap((animation) => {
          const effect = animation.effect as KeyframeEffect | null;
          const target = effect?.target as Element | null;
          if (!effect || !target?.closest(".cv-spinner[data-working]")) return [];
          const name = (animation as CSSAnimation).animationName ?? "?";
          const opacity = effect.getKeyframes().some((frame) => "opacity" in frame);
          return [`${target.getAttribute("class")} ${name}${opacity ? " opacity" : ""}`];
        }),
    );
  }

  // Leo 2026-10-21, after #22826 made agent work a breathing dot: "who brought back the blinkers!? we
  // had spinners properly going", then "we need to GUARANTEE the breathing dot doesn't come back".
  // Agent work is the turning spinner on every page: with no `data-working-look`, with `spinner`, with
  // an old stored `breathe` sent by the app's theme push, or any other value. Only the Debug `shimmer`
  // look swaps it, for a still dot. No look ever loops a working mark's opacity.
  test("agent work turns as the spinner in every look, and no working mark breathes", async () => {
    const looks: Record<string, { all: string[]; working: string[]; dot: string; arc: string }> = {};
    for (const look of ["(none)", "breathe", "spinner", "shimmer", "pulse"]) {
      const p = await page(`${desktop}${pane}`, `<span class="cv-spinner"></span>${working}`, "no-preference");
      if (look !== "(none)") {
        // The app's path: the bootstrap, then a theme push carrying the look (WebTheme.payloadJSON).
        await p.addScriptTag({ content: bootstrap });
        await p.evaluate(
          (value) =>
            (window as unknown as { cmuxTheme: { apply(payload: object): void } }).cmuxTheme.apply({
              variables: {},
              colorScheme: "light",
              workingLook: value,
            }),
          look,
        );
        await p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        expect(await p.evaluate(() => document.documentElement.dataset.workingLook)).toBe(look);
      }
      const display = (selector: string) => p.$eval(selector, (node) => getComputedStyle(node).display);
      looks[look] = {
        all: (await loops(p)).map((loop) => loop.replace(/\s+/g, " ")).sort(),
        working: (await workingMarkLoops(p)).sort(),
        dot: await display(".cv-spinner[data-working] .cv-spinner__dot"),
        arc: await display(".cv-spinner[data-working] .cv-spinner__arc"),
      };
      await p.close();
    }
    for (const look of ["(none)", "breathe", "spinner", "pulse"]) {
      expect({ look, ...looks[look] }).toEqual({
        look,
        all: ["cv-spinner cmux-spin", "cv-spinner cmux-spin"],
        working: ["cv-spinner cmux-spin"],
        dot: "none",
        arc: "inline",
      });
    }
    // Debug only: a still dot, and the band crosses the row's words; loading keeps the spinner.
    expect(looks.shimmer).toEqual({
      all: ["cv-spinner cmux-spin", "cv-tool__text cmux-shimmer"],
      working: [],
      dot: "inline",
      arc: "none",
    });
    for (const [look, result] of Object.entries(looks)) {
      expect({ look, opacity: result.working.filter((loop) => loop.endsWith(" opacity")) }).toEqual({
        look,
        opacity: [],
      });
    }
  });

  test("no stylesheet or script brings the breathing look back", () => {
    const banned = [
      /cmux-breathe\b/,
      /--cmux-breath-period/,
      /data-working-look="breathe"/,
      /workingLook:\s*"breathe"/,
    ];
    const hits: string[] = [];
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (entry.name !== "node_modules" && entry.name !== "generated") walk(full);
        } else if (/\.(css|ts|tsx)$/.test(entry.name)) {
          const text = readFileSync(full, "utf8");
          for (const pattern of banned) if (pattern.test(text)) hits.push(`${path.relative(src, full)}: ${pattern}`);
        }
      }
    };
    walk(src);
    expect(hits).toEqual([]);
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

  test("the theme push sets the attribute the stylesheets read", async () => {
    const p = await page("", "", "no-preference", "static");
    const look = await p.evaluate(() => document.documentElement.dataset.statusIndicators);
    await p.close();
    expect(look).toBe("static");
  });

  test("the static triangle keeps the dot's box: nothing beside it moves", async () => {
    const body = `<div style="display:flex"><span class="acpmux-floating-status" data-status="attention"></span><b>chat</b></div>`;
    const box = async (look: "static" | "animated") => {
      const p = await page(`${desktop}${pane}`, body, "no-preference", look);
      const rect = await p.$eval(".acpmux-floating-status", (node) => {
        const r = node.getBoundingClientRect();
        const next = (node.nextElementSibling as HTMLElement).getBoundingClientRect();
        return [r.width, r.height, next.left];
      });
      await p.close();
      return rect;
    };
    expect(await box("static")).toEqual(await box("animated"));
  });
});
