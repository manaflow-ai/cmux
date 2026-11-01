// cmux-web-test-timeout: 300
// Send, Stop, ↵ and the queue's Send are plain glyphs, as the mic is (Leo 2026-10-21: "Send, Stop and
// Queue buttons are drawn as filled light circles right now. WHAT IS THIS STYLING? WHY ARE THERE
// CIRCLES. Use plain glyphs like the mic ... Match Claude Code desktop. A hover state is fine, but no
// solid discs."). In the chat composer and on the New Tab page:
//   - at rest each is its glyph alone, in the secondary text color (--agent-muted, the mic's; dimmed
//     further while there is nothing to send), with no fill, no ring and no shadow; the glyph has the
//     mic's size and stroke;
//   - hovered it takes the mic's soft pill and keeps its color, and a press changes nothing more;
//   - the Esc-armed Stop keeps its glyph and footprint and says so in its color, never a pill;
//   - mid-turn every control sits inside the box, and none is filled in a blue.
//
// Real Chromium and WebKit on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-plain-glyphs.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-plain-glyphs.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-plain-glyphs: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer plain glyphs", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string, accent?: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width: 760, theme: "Catppuccin Mocha", accent })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "composer-mic" } });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "quiet-chips" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing (a looping animation never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );

  const open = async (engine: string, entry: string, variant: string, accent?: string) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await page.goto(stageURL(entry, variant, accent));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };

  /** Types a prompt into the box's field and waits for `wait` to show. */
  const type = async (page: Page, box: string, wait: string, text = "Retry the flaky test") => {
    await page.locator(`${box} .acpmux-md, ${box} .nt-field`).first().click();
    await page.keyboard.type(text);
    await page.locator(`${box} ${wait}`).first().waitFor();
    await page.mouse.move(1, 1);
    await eased(page);
  };

  type Look = {
    fill: string;
    shadow: string;
    outline: string;
    color: string;
    text: string;
    muted: string;
    width: number;
    glyph: { width: number; height: number; stroke: string } | null;
    inBox: boolean;
  };
  /** How the control `selector` draws at this moment, and the composer's text color. */
  const look = (page: Page, selector: string, box: string) =>
    page.evaluate(
      ({ selector, box }): Look => {
        const control = document.querySelector<HTMLElement>(selector)!;
        const style = getComputedStyle(control);
        const ink = (token: string) => {
          const probe = document.createElement("span");
          probe.style.color = `var(${token})`;
          control.parentElement!.appendChild(probe);
          const color = getComputedStyle(probe).color;
          probe.remove();
          return color;
        };
        const text = ink("--agent-text");
        const muted = ink("--agent-muted");
        const svg = control.querySelector("svg");
        const stroke = svg?.querySelector("path, rect");
        const r = control.getBoundingClientRect();
        const b = document.querySelector(box)!.getBoundingClientRect();
        return {
          fill: style.backgroundColor,
          shadow: style.boxShadow,
          outline: style.outlineStyle,
          color: style.color,
          text,
          muted,
          width: r.width,
          glyph: svg
            ? {
                width: svg.getBoundingClientRect().width,
                height: svg.getBoundingClientRect().height,
                stroke: stroke ? getComputedStyle(stroke).strokeWidth : "",
              }
            : null,
          inBox:
            r.left >= b.left - 0.5 && r.right <= b.right + 0.5 && r.top >= b.top - 0.5 && r.bottom <= b.bottom + 0.5,
        };
      },
      { selector, box },
    );
  const clear = (color: string) => color === "rgba(0, 0, 0, 0)" || color === "transparent";
  /** A plain glyph at rest: no disc, no ring, no shadow, and the mic's glyph. */
  const plain = (name: string, at: Look, mic: Look) => {
    const problems: string[] = [];
    // The secondary text color is its own token, a step below the text (else the color checks prove nothing).
    if (at.muted === at.text) problems.push(`the secondary text color ${at.muted} is the text color`);
    if (!clear(at.fill)) problems.push(`${name} is filled ${at.fill}`);
    if (at.shadow !== "none") problems.push(`${name} draws a shadow or ring ${at.shadow}`);
    if (!at.glyph) problems.push(`${name} draws no glyph`);
    else if (Math.abs(at.glyph.width - mic.glyph!.width) > 0.5 || Math.abs(at.glyph.height - mic.glyph!.height) > 0.5)
      problems.push(`${name}'s glyph is ${at.glyph.width}×${at.glyph.height}, the mic's ${mic.glyph!.width}`);
    return problems;
  };
  /** The background the mic takes under the pointer: the composer's soft hover pill. */
  const micPill = async (page: Page, box: string) => {
    await page.locator(`${box} .acpmux-mic`).first().hover();
    await eased(page);
    const pill = (await look(page, `${box} .acpmux-mic`, box)).fill;
    await page.mouse.move(1, 1);
    await eased(page);
    return pill;
  };

  const CHAT_BOX = ".acpmux-composer-box";
  const NEW_TAB_BOX = ".nt-box";

  for (const [engine] of engines) {
    test(`${engine}: the chat's Send is the mic's plain glyph in the secondary text color; hover is the mic's pill, a press adds nothing`, async () => {
      const page = await open(engine, "agent-pane.composer", "quiet-chips");
      await type(page, CHAT_BOX, ".acpmux-send");
      const mic = await look(page, `${CHAT_BOX} .acpmux-mic`, CHAT_BOX);
      const send = await look(page, `${CHAT_BOX} .acpmux-send`, CHAT_BOX);
      const problems = plain("Send", send, mic);
      if (send.color !== send.muted)
        problems.push(`Send with a draft is ${send.color}, not the secondary text ${send.muted}`);
      if (mic.color !== mic.muted) problems.push(`the mic is ${mic.color}, not the secondary text ${mic.muted}`);
      if (send.glyph?.stroke !== mic.glyph?.stroke)
        problems.push(`Send's stroke is ${send.glyph?.stroke}, the mic's ${mic.glyph?.stroke}`);
      const pill = await micPill(page, CHAT_BOX);
      await page.locator(`${CHAT_BOX} .acpmux-send`).hover();
      await eased(page);
      const hovered = await look(page, `${CHAT_BOX} .acpmux-send`, CHAT_BOX);
      if (hovered.fill !== pill) problems.push(`hovered Send is ${hovered.fill}, the mic's pill is ${pill}`);
      if (hovered.color !== send.color) problems.push(`hovered Send turns ${hovered.color}, at rest ${send.color}`);
      await page.mouse.down();
      await eased(page);
      const pressed = await look(page, `${CHAT_BOX} .acpmux-send`, CHAT_BOX);
      // Release off the button, so the press sends nothing.
      await page.mouse.move(1, 1);
      await page.mouse.up();
      if (pressed.fill !== pill) problems.push(`pressed Send is ${pressed.fill}, not the hover pill ${pill}`);
      await page.close();
      expect(problems).toEqual([]);
    });

    test(`${engine}: mid-turn, Stop and then the one steering Send are plain glyphs inside the box`, async () => {
      const problems: string[] = [];
      for (const [name, variant, selector] of [
        ["Stop", "working", `${CHAT_BOX} .acpmux-cancel`],
        // One send control (Leo 2026-10-31: "THE F***ING TWO SEND BUTTONS"): a typed prompt turns
        // Stop's slot into Send, which steers as Return does; no second ↵ control.
        ["the steering Send", "working-steer", `${CHAT_BOX} .acpmux-send:not(.acpmux-cancel)`],
      ] as const) {
        const page = await open(engine, "agent-pane.composer", variant);
        await page.locator(selector).waitFor();
        const mic = await look(page, `${CHAT_BOX} .acpmux-mic`, CHAT_BOX);
        const at = await look(page, selector, CHAT_BOX);
        problems.push(...plain(name, at, mic));
        if (at.color !== at.muted) problems.push(`${name} is ${at.color}, not the secondary text ${at.muted}`);
        if (!at.inBox) problems.push(`${name} pokes out of the box`);
        if (at.glyph?.stroke !== mic.glyph?.stroke)
          problems.push(`${name}'s stroke is ${at.glyph?.stroke}, the mic's ${mic.glyph?.stroke}`);
        const sends = await page.locator(`${CHAT_BOX} :is(.acpmux-send, .acpmux-cancel)`).count();
        if (sends !== 1) problems.push(`${variant}: ${sends} send-like controls, not one`);
        await page.close();
      }
      expect(problems).toEqual([]);
    });

    test(`${engine}: an agent that cannot steer queues with a plain Send inside the box, never a blue disc`, async () => {
      const page = await open(engine, "agent-pane.composer", "working-queue");
      await page.locator(`${CHAT_BOX} .acpmux-send:not(.acpmux-cancel)`).waitFor();
      const mic = await look(page, `${CHAT_BOX} .acpmux-mic`, CHAT_BOX);
      const queue = await look(page, `${CHAT_BOX} .acpmux-send:not(.acpmux-cancel)`, CHAT_BOX);
      const problems = plain("the queue's Send", queue, mic);
      if (queue.color !== queue.muted)
        problems.push(`the queue's Send is ${queue.color}, not the secondary text ${queue.muted}`);
      if (!queue.inBox) problems.push("the queue's Send pokes out of the box");
      // No control of the composer is filled in a blue (the theme's accent or a system blue).
      const blue = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-composer button")].flatMap((button) => {
          const fill = getComputedStyle(button).backgroundColor;
          const [r = 0, g = 0, b = 0, a = 1] = [...fill.matchAll(/[\d.]+/g)].map((match) => Number(match[0]));
          const scale = fill.startsWith("color(") ? 255 : 1;
          return a > 0.3 && (b - Math.max(r, g)) * scale > 24 ? [`${button.className}: ${fill}`] : [];
        }),
      );
      problems.push(...blue.map((entry) => `blue control ${entry}`));
      await page.close();
      expect(problems).toEqual([]);
    });

    test(`${engine}: the Esc-armed Stop keeps its glyph and footprint, cued by its color`, async () => {
      // A theme with an accent (the app's "magenta"): a neutral theme's accent is its text color.
      const page = await open(engine, "agent-pane.composer", "working", "magenta");
      await page.locator(`${CHAT_BOX} .acpmux-md`).first().click();
      const rest = await look(page, `${CHAT_BOX} .acpmux-cancel`, CHAT_BOX);
      await page.keyboard.press("Escape");
      await page.locator(`${CHAT_BOX} .acpmux-cancel[data-escape-armed]`).waitFor();
      await eased(page);
      const armed = await look(page, `${CHAT_BOX} .acpmux-cancel`, CHAT_BOX);
      await page.close();
      const problems: string[] = [];
      if (!clear(armed.fill)) problems.push(`the armed Stop is filled ${armed.fill}`);
      if (!armed.glyph) problems.push("the armed Stop draws no glyph");
      if (Math.abs(armed.width - rest.width) > 0.5)
        problems.push(`the armed Stop widens ${rest.width} -> ${armed.width}`);
      if (armed.color === rest.color) problems.push("the armed Stop looks the same as Stop");
      expect(problems).toEqual([]);
    });

    test(`${engine}: the New Tab Send is a dim glyph with nothing to send and the secondary text color with a draft, never a disc`, async () => {
      const page = await open(engine, "agent-pane.new-tab", "composer-mic");
      const mic = await look(page, `${NEW_TAB_BOX} .acpmux-mic`, NEW_TAB_BOX);
      const off = await look(page, `${NEW_TAB_BOX} .acpmux-send`, NEW_TAB_BOX);
      await type(page, NEW_TAB_BOX, ".acpmux-send-ready");
      const ready = await look(page, `${NEW_TAB_BOX} .acpmux-send`, NEW_TAB_BOX);
      await page.close();
      const problems = [...plain("the off Send", off, mic), ...plain("Send", ready, mic)];
      if (off.color === off.text || off.color === off.muted) problems.push("the off Send is as bright as a ready Send");
      if (ready.color !== ready.muted)
        problems.push(`Send with a draft is ${ready.color}, not the secondary text ${ready.muted}`);
      expect(problems).toEqual([]);
    });
  }
});
