// Leo 2026-10-13 (cx-sya4n): blinking and pulsing lights give a teammate headaches. The native
// Static status indicators setting (or macOS Reduce Motion) reaches every page as
// `data-status-indicators="static"` on the root: the app's WebTheme bootstrap sets it from the theme
// payload (`statusIndicators`), which this test runs as the app does, and under it, or under Reduce
// Motion, no web loop may run: the mic's wait pulse, the model picker and harness spinners, the
// floating chat's breathing dot, the Thinking sweep, the todo list's spinner, the static Jump to
// Latest arrow and Home's "writing" pulse.
// The diff viewer does not get the pane's theme, so its spinners stop under Reduce Motion alone.
// Static also gives the color-only marks a shape each.
// This loads the real stylesheets in Chromium and lists the animations that never end.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ToolText } from "../src/agent-session/acpmux/conversation/ToolText";
import { setWorkingLook, type WorkingLook } from "../src/agent-session/shared/workingLook";
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

  // A running transcript row's working mark (Spinner, WORKING-LOOK) with its words, as the row
  // draws them in `look` (ToolText: the words and, in the shimmer look only, the lit layer; the
  // look reaches ToolText from the theme push, workingLook.ts, as it does in the pane).
  const working = (look?: WorkingLook) => {
    setWorkingLook(look);
    const row =
      `<div class="cv-tool"><span class="cv-tool__icon"><span class="cv-spinner" data-working>` +
      `<span class="cv-spinner__arc"></span><span class="cv-spinner__dot"></span></span></span>` +
      renderToStaticMarkup(createElement(ToolText, { working: true, children: "Compacting" })) +
      `</div>`;
    setWorkingLook(undefined);
    return row;
  };
  const paneLoops = (look?: WorkingLook) =>
    `<button class="acpmux-mic" data-state="starting">mic</button>` +
    `<span class="acpmux-mp-refresh-spinner"></span><span class="acpmux-harness-spinner"></span>` +
    `<span class="acpmux-floating-status" data-status="streaming"></span>` +
    `<div class="cv-md"><span class="cv-thinking">Thinking</span></div>` +
    `<button class="acpmux-jump-latest" data-shown><span class="acpmux-jump-latest__arrow">↓</span></button>` +
    `<ul class="cv-plan"><li class="cv-plan__item" data-status="in_progress"><span class="cv-plan__mark"></span></li></ul>` +
    `<span class="cv-spinner"></span>` +
    working(look) +
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
    const p = await page(`${desktop}${pane}${home}${diff}`, paneLoops() + diffLoops, "no-preference");
    const running = await loops(p);
    await p.close();
    expect(running.length).toBeGreaterThanOrEqual(6);
    // The todo list's spinner among them, so the Static and Reduce Motion checks cover it.
    expect(running.some((loop) => loop.startsWith("cv-plan__mark") && loop.endsWith("cmux-spin"))).toBe(true);
    // The running rows' spinner (compaction, tool runs) too: it once had no rule and never turned.
    expect(running.some((loop) => loop.startsWith("cv-spinner") && loop.endsWith("cmux-spin"))).toBe(true);
    // Agent work uses the shared spinner by default; no working mark runs the breathing keyframe.
    expect(running.filter((loop) => loop.startsWith("cv-spinner ") && loop.endsWith("cmux-spin")).length).toBe(2);
    expect(running.some((loop) => loop.startsWith("cv-spinner ") && loop.endsWith("cmux-breathe"))).toBe(false);
  });

  /** Infinite opacity or scale animations running on a working mark, including its children. */
  async function workingMarkPulseLoops(p: Page): Promise<string[]> {
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
          const props = new Set(
            effect
              .getKeyframes()
              .flatMap((frame) => [
                "opacity" in frame ? "opacity" : "",
                "scale" in frame || (typeof frame.transform === "string" && frame.transform.includes("scale"))
                  ? "scale"
                  : "",
              ])
              .filter(Boolean),
          );
          return [...props]
            .filter((property) => property === "opacity" || property === "scale")
            .map((property) => `${target.getAttribute("class")} ${property}`);
        }),
    );
  }

  test("default and unknown working looks never pulse; breathing requires an explicit pick", async () => {
    const looks: Record<string, { loops: string[]; pulses: string[] }> = {};
    for (const look of ["(none)", "breathe", "shimmer", "spinner", "pulse"]) {
      // The row as ToolText draws it under the look the theme pushed (an unknown value reaches it as none).
      const named = look === "breathe" || look === "shimmer" || look === "spinner" ? look : undefined;
      const p = await page(`${desktop}${pane}`, `<span class="cv-spinner"></span>${working(named)}`, "no-preference");
      if (look !== "(none)") {
        await p.evaluate((value) => {
          document.documentElement.dataset.workingLook = value;
          return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        }, look);
      }
      looks[look] = {
        loops: (await loops(p)).map((loop) => loop.replace(/\s+/g, " ")).sort(),
        pulses: (await workingMarkPulseLoops(p)).sort(),
      };
      await p.close();
    }
    for (const look of ["(none)", "spinner", "pulse"]) {
      expect(looks[look]).toEqual({
        loops: ["cv-spinner cmux-spin", "cv-spinner cmux-spin"],
        pulses: [],
      });
    }
    expect(looks.breathe).toEqual({
      loops: ["cv-spinner cmux-breathe", "cv-spinner cmux-spin"],
      pulses: ["cv-spinner opacity"],
    });
    // The shimmer look sweeps the row's words with the compositor's two loops (ToolText.tsx).
    expect(looks.shimmer).toEqual({
      loops: ["cv-spinner cmux-spin", "cv-tool__lit cmux-shimmer-lit", "cv-tool__shine cmux-shimmer-band"],
      pulses: [],
    });
  });

  test("explicit breathing stops under Reduce Motion, static status, or completion", async () => {
    for (const policy of ["reduce", "static", "complete"]) {
      const p = await page(`${desktop}${pane}`, working("breathe"), "no-preference");
      try {
        await p.evaluate(() => {
          document.documentElement.dataset.workingLook = "breathe";
          return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        });
        expect((await loops(p)).map((loop) => loop.replace(/\s+/g, " "))).toEqual(["cv-spinner cmux-breathe"]);
        if (policy === "reduce") await p.emulateMedia({ reducedMotion: "reduce" });
        else
          await p.evaluate((value) => {
            if (value === "static") document.documentElement.dataset.statusIndicators = "static";
            else document.querySelector(".cv-tool")?.remove();
          }, policy);
        await p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        expect(await loops(p)).toEqual([]);
      } finally {
        await p.close();
      }
    }
  });

  // The shimmer look rests a running row's words in the dim color only where ToolText mounts its
  // band over them. A running row that draws its words some other way (a raw `cv-tool__text` span
  // next to the spinner, as the dispatch card's line once did) keeps its own color: it has no band,
  // so dimming it made the row look idle in the look whose purpose is to show work.
  test("the shimmer look dims only words that carry its band", async () => {
    const spinner =
      `<span class="cv-tool__icon"><span class="cv-spinner" data-working>` +
      `<span class="cv-spinner__arc"></span><span class="cv-spinner__dot"></span></span></span>`;
    const body =
      `<div class="cv-tool" id="plain">${spinner}<span class="cv-tool__text">Dispatching</span></div>` +
      working("shimmer").replace('<div class="cv-tool">', '<div class="cv-tool" id="banded">') +
      `<div class="cv-tool" id="idle"><span class="cv-tool__icon"></span><span class="cv-tool__text">Read</span></div>`;
    // Distinct theme text colors, so dim and normal words read apart. The rows carry an own color
    // apart from the dim one (a settled row's, a card's): a bare `.cv-tool` already rests in the dim
    // color, so with it the band's dimming and the row's own color read the same and no CSS passes.
    const theme =
      `:root { --agent-text: rgb(240, 240, 230); --agent-soft: rgb(120, 120, 110); }` +
      `.cv-tool { color: rgb(200, 200, 190); }`;
    const p = await inLook(await page(`${desktop}${pane}${theme}`, body, "no-preference"), "shimmer");
    const color = (id: string) =>
      p.evaluate((row) => getComputedStyle(document.querySelector(`#${row} .cv-tool__text`)!).color, id);
    const [plain, banded, idle] = [await color("plain"), await color("banded"), await color("idle")];
    await p.close();
    expect(banded).toBe("rgb(120, 120, 110)");
    expect(idle).toBe("rgb(200, 200, 190)");
    expect(plain).toBe(idle);
  });

  /** Every running endless animation that moves more than the compositor can (transform,
   * opacity): `<element> <keyframes>: <properties>`. */
  async function paintingLoops(p: Page): Promise<string[]> {
    return p.evaluate(() => {
      const compositor = new Set(["transform", "translate", "rotate", "scale", "opacity"]);
      const timing = new Set(["offset", "computedOffset", "easing", "composite"]);
      return document
        .getAnimations()
        .filter(
          (animation) => animation.effect?.getTiming().iterations === Infinity && animation.playState === "running",
        )
        .flatMap((animation) => {
          const effect = animation.effect as KeyframeEffect | null;
          const moved = new Set(
            (effect?.getKeyframes() ?? []).flatMap((frame) => Object.keys(frame).filter((key) => !timing.has(key))),
          );
          const painted = [...moved].filter((property) => !compositor.has(property));
          if (!painted.length) return [];
          const target = effect?.target as Element | null;
          const name = (animation as CSSAnimation).animationName ?? "?";
          return [`${target?.className || target?.tagName} ${name}: ${painted.sort().join(", ")}`];
        });
    });
  }

  // perf-lead row 23 (scrolling at full refresh): a loop that animates a painted property (the
  // shimmer's `background-position` once) repaints its element on the page's main thread every
  // frame, for as long as the row runs, under every scroll. Each look agent work can take, and the
  // other pane, Home and diff loops, move on the compositor only.
  test("every pane loop, in each working look, animates only what the compositor moves", async () => {
    const painting: Record<string, string[]> = {};
    for (const look of ["breathe", "shimmer", "spinner"] as const) {
      const p = await page(`${desktop}${pane}${home}${diff}`, paneLoops(look) + diffLoops, "no-preference");
      await p.evaluate((value) => {
        document.documentElement.dataset.workingLook = value;
        return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      }, look);
      painting[look] = await paintingLoops(p);
      await p.close();
    }
    expect(painting).toEqual({ breathe: [], shimmer: [], spinner: [] });
  });

  /** `page`, with `look` set on the root as the theme push sets it (undefined: the default). */
  async function inLook(p: Page, look?: WorkingLook): Promise<Page> {
    if (look) {
      await p.evaluate((value) => {
        document.documentElement.dataset.workingLook = value;
        return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      }, look);
    }
    return p;
  }

  // In the default look and in the shimmer look, whose running rows carry the lit layer.
  for (const look of [undefined, "shimmer"] as const) {
    test(`Static status indicators stop every pane loop (${look ?? "default"} look)`, async () => {
      const p = await inLook(await page(`${desktop}${pane}${home}`, paneLoops(look), "no-preference", "static"), look);
      const running = await loops(p);
      await p.close();
      expect(running).toEqual([]);
    });

    test(`Reduce Motion stops every loop, the diff viewer's too (${look ?? "default"} look)`, async () => {
      const p = await inLook(
        await page(`${desktop}${pane}${home}${diff}`, paneLoops(look) + diffLoops, "reduce"),
        look,
      );
      const running = await loops(p);
      await p.close();
      expect(running).toEqual([]);
    });
  }

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
      };
    });
    await p.close();
    expect(new Set(shapes.floating).size).toBe(2);
    expect(new Set(shapes.summary).size).toBe(3);
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
