// Leo, 2026-10-14: tooltips are glass, not a solid box; 2026-10-21: "WHERE IS THE GLASS EVERYWHERE,
// all these hover tooltips and hover previews". A tooltip is the liquid glass (`.ui-glass`,
// ui/glass/glass.css) in the shared transient frost, in every glass mode: a strong backdrop blur under a tint
// dense enough that the text reads over anything (the host's, TooltipSurface.swift), the glass rim as
// its one edge and a small tight shadow; the opaque popup surface under Reduce Transparency.
// A tooltip shows and goes in one frame, with no fade and no rise, under every motion setting (Leo,
// 2026-11-11: "the fade-in, the fade-out, is just so stupid... It's just sluggish.").
//
// The page is the real stylesheets and the real title tooltip (ui/titleTooltips.ts, bundled) in
// Chromium; the pointer is Playwright's mouse.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tooltip-surface.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/popupSurface.css", "ui/ui.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");

  // The title tooltip, bundled for the page.
  const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tooltip-surface-")), "entry.ts");
  fs.writeFileSync(
    entry,
    `import { installTooltips } from ${JSON.stringify(path.join(source, "ui/titleTooltips.ts"))};
     (window as unknown as { install: () => void }).install = () => void installTooltips(document);`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();
  fs.rmSync(path.dirname(entry), { recursive: true, force: true });

  // A dark and a light theme as the host sets them (WebTheme.swift); a test adds the host's tint
  // (--cmux-tooltip-tint) where it needs one.
  const themes = {
    dark: { surface: "rgb(30, 30, 46)", popup: "rgb(52, 49, 68)", text: "rgb(224, 222, 244)" },
    light: { surface: "rgb(250, 250, 250)", popup: "rgb(255, 255, 255)", text: "rgb(36, 41, 47)" },
  };
  const theme = (name: keyof typeof themes, extra = "") =>
    `--cmux-surface-solid:${themes[name].surface};--cmux-popup-surface:${themes[name].popup};` +
    `--cmux-text:${themes[name].text};` +
    `--cmux-separator:rgba(128, 128, 128, 0.25);${extra}`;

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => browser?.close());

  const toolbar = `<div style="display:flex;gap:6px;padding:20px">
    ${["Back", "Forward", "Reload"].map((label, i) => `<button id="b${i}" title="${label}" style="width:28px;height:28px"></button>`).join("")}
  </div>`;

  async function open(style: string, body = toolbar, options: { reducedMotion?: "reduce" } = {}) {
    const page = await browser.newPage({
      viewport: { width: 500, height: 300 },
      deviceScaleFactor: 2,
    });
    if (options.reducedMotion) await page.emulateMedia({ reducedMotion: options.reducedMotion });
    await page.setContent(
      `<!doctype html><html style="${style}"><head><style>${css}</style></head><body style="margin:0">${body}</body></html>`,
    );
    await page.addScriptTag({ content: script });
    await page.evaluate(() => (window as unknown as { install: () => void }).install());
    return page;
  }

  /** The tooltip's running transitions: property, duration and the opacity at each sampled time. */
  const transitions = (page: Page, at: number[] = []) =>
    page.evaluate((times) => {
      const tip = document.querySelector<HTMLElement>(".ui-title-tooltip")!;
      return tip.getAnimations().map((animation) => {
        const transition = animation as CSSTransition;
        const duration = Number(animation.effect?.getTiming().duration);
        const samples = times.map((time) => {
          animation.pause();
          animation.currentTime = time;
          const style = getComputedStyle(tip);
          return { time, opacity: Number(style.opacity), translate: style.translate };
        });
        return { property: transition.transitionProperty, duration, samples };
      });
    }, at);

  const hoverAndWait = async (page: Page, id: string) => {
    const box = (await page.locator(`#${id}`).boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.waitForFunction(() => !document.querySelector<HTMLElement>(".ui-title-tooltip")!.hidden, null, {
      timeout: 3000,
    });
  };

  test("the first tooltip shows at once with no fade or rise; a warm neighbor's is there at once; it goes at once", async () => {
    const page = await open(theme("dark"));
    await page.mouse.move(400, 250);
    await hoverAndWait(page, "b0");
    expect(await transitions(page)).toEqual([]);
    expect(
      await page.$eval(".ui-title-tooltip", (tip) => ({
        opacity: getComputedStyle(tip).opacity,
        translate: getComputedStyle(tip).translate,
      })),
    ).toEqual({ opacity: "1", translate: "none" });

    // Straight to the neighbor: its text at once.
    const box = (await page.locator("#b1").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.waitForFunction(() => document.querySelector(".ui-title-tooltip")!.textContent === "Forward");
    expect(await transitions(page)).toEqual([]);
    expect(await page.$eval(".ui-title-tooltip", (tip) => getComputedStyle(tip).opacity)).toBe("1");

    // Away: hidden in the frame the hide runs, with no fade.
    await page.mouse.move(400, 250);
    await page.waitForFunction(() => document.querySelector<HTMLElement>(".ui-title-tooltip")!.hidden, null, {
      timeout: 2000,
    });
    expect(await transitions(page)).toEqual([]);

    // A click puts a shown tooltip away at once over the menu it opens.
    await hoverAndWait(page, "b2");
    await page.mouse.down();
    expect(
      await page.$eval(".ui-title-tooltip", (tip) => ({
        hidden: (tip as HTMLElement).hidden,
        ending: tip.hasAttribute("data-ending-style"),
      })),
    ).toEqual({ hidden: true, ending: false });
    await page.mouse.up();
    await page.close();
  });

  test("under Reduce Motion the first tooltip shows at once too", async () => {
    const page = await open(theme("dark"), toolbar, { reducedMotion: "reduce" });
    await page.mouse.move(400, 250);
    await hoverAndWait(page, "b0");
    expect(await transitions(page)).toEqual([]);
    await page.close();
  });

  const surfaceOf = (page: Page) =>
    page.$eval(".ui-title-tooltip", (tip) => {
      const style = getComputedStyle(tip);
      return {
        background: style.backgroundColor,
        border: style.borderTopColor,
        blur: style.backdropFilter,
        // The rim's width (Chromium draws a border under 1px as 1px; WebKit, the app's engine, keeps it).
        rim: style.getPropertyValue("--tooltip-rim-width").trim(),
        shadow: style.boxShadow,
      };
    });

  test("the tooltip is the liquid glass in the host's tooltip tint, a device-pixel rim and a tight shadow, in every glass mode", async () => {
    const tint = "rgba(52, 49, 68, 0.9)";
    // Plain glass (the default), the lens while it draws, and Spectrum: the lens's clearer root
    // tint never reaches a tooltip.
    for (const mode of ["plain", "lens", "spectrum"] as const) {
      const page = await open(theme("dark", `--cmux-tooltip-tint:${tint}`));
      if (mode !== "plain")
        await page.evaluate((glass) => {
          document.documentElement.setAttribute("data-glass", glass);
          document.documentElement.setAttribute("data-glass-lens", "");
        }, mode);
      await hoverAndWait(page, "b0");
      const surface = await surfaceOf(page);
      expect({ mode, background: surface.background, blur: surface.blur }).toEqual({
        mode,
        background: tint,
        blur: "blur(32px) saturate(1.6)",
      });
      // The glass rim is the one edge: the border keeps its width, clear.
      expect(surface.border).toBe("rgba(0, 0, 0, 0)");
      // One device pixel at 2x.
      expect(surface.rim).toBe("0.5px");
      // The rim (an inset hairline), then elevation 1.
      expect(surface.shadow).toContain("inset");
      expect(surface.shadow).toContain("0px 1px 2px 0px");
      await page.close();
    }
  });

  /** Applies the Reduce Transparency media blocks' rules (Chromium has no emulation of the setting). */
  const reduceTransparency = (page: Page) =>
    page.evaluate(() => {
      const blocks = [...document.styleSheets]
        .flatMap((sheet) => [...sheet.cssRules])
        .filter(
          (rule): rule is CSSMediaRule =>
            rule instanceof CSSMediaRule && rule.conditionText.includes("prefers-reduced-transparency"),
        );
      if (!blocks.length) throw new Error("no Reduce Transparency block");
      const style = document.createElement("style");
      style.textContent = blocks.flatMap((block) => [...block.cssRules].map((rule) => rule.cssText)).join("\n");
      document.head.append(style);
    });

  test("Reduce Transparency draws the opaque popup surface, unblurred", async () => {
    for (const reduce of ["host", "system"] as const) {
      const opened = await open(theme("dark", "--cmux-tooltip-tint:rgba(52, 49, 68, 0.9)"));
      if (reduce === "host")
        await opened.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
      else await reduceTransparency(opened);
      await hoverAndWait(opened, "b0");
      const surface = await surfaceOf(opened);
      expect({ reduce, background: surface.background, blur: surface.blur }).toEqual({
        reduce,
        background: themes.dark.popup,
        blur: "none",
      });
      await opened.close();
    }
  });

  /** WCAG contrast between two sRGB colors. */
  const contrast = (a: number[], b: number[]) => {
    const luminance = ([r, g, b]: number[]) => {
      const channel = (value: number) => {
        const c = value / 255;
        return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
    };
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const rgb = (value: string) =>
    value
      .match(/[\d.]+/g)!
      .slice(0, 3)
      .map(Number);

  /** The host's tint (TooltipSurface.tintAlpha, sent as --cmux-tooltip-tint): the popup surface at
   * the least alpha from minimumTintAlpha, in 1% steps, at which the text keeps 4.5:1 over the tint
   * laid on pure black and on pure white. The pages' own fallback is that floor alone (60%), which a
   * dark theme's text does not read on over white (about 0.7 there; Leo 2026-10-18, #21785), so the
   * app always sends this tint and the check below draws with it. */
  const minimumTintAlpha = Number(
    fs
      .readFileSync(
        path.resolve(
          import.meta.dir,
          "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tooltip/TooltipSurface.swift",
        ),
        "utf8",
      )
      .match(/static let minimumTintAlpha: Double = ([\d.]+)/)![1],
  );
  const hostTint = (name: keyof typeof themes) => {
    const fill = rgb(themes[name].popup);
    const ink = rgb(themes[name].text);
    const over = (alpha: number, backdrop: number) => fill.map((c) => c * alpha + backdrop * (1 - alpha));
    for (let percent = Math.round(minimumTintAlpha * 100); percent < 100; percent++) {
      const alpha = percent / 100;
      if (Math.min(contrast(ink, over(alpha, 0)), contrast(ink, over(alpha, 255))) >= 4.5)
        return `rgba(${fill.join(", ")}, ${alpha})`;
    }
    return `rgb(${fill.join(", ")})`;
  };

  test("the tooltip's text keeps 4.5:1 over pure black and pure white, light and dark, glass and opaque", async () => {
    const seen: Record<string, number> = {};
    for (const name of ["dark", "light"] as const) {
      for (const backdrop of ["#000", "#fff"]) {
        for (const reduce of [false, true]) {
          const body = `<div style="position:fixed;inset:0;z-index:-1;background:${backdrop}"></div>${toolbar}`;
          const page = await open(theme(name, `--cmux-tooltip-tint:${hostTint(name)}`), body);
          if (reduce) await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
          await hoverAndWait(page, "b0");
          await page.evaluate(() =>
            document
              .querySelector(".ui-title-tooltip")!
              .getAnimations()
              .forEach((a) => a.finish()),
          );
          const tip = (await page.locator(".ui-title-tooltip").boundingBox())!;
          // A pixel of the surface inside the rim, left of the text's first glyph.
          const shot = PNG.sync.read(
            await page.screenshot({
              clip: { x: tip.x + 2, y: tip.y + tip.height / 2, width: 1, height: 1 },
            }),
          );
          const fill = [shot.data[0], shot.data[1], shot.data[2]];
          const ratio = contrast(rgb(themes[name].text), fill);
          seen[`${name} over ${backdrop}${reduce ? " (Reduce Transparency)" : ""}`] = Math.round(ratio * 100) / 100;
          await page.close();
        }
      }
    }
    const failing = Object.entries(seen).filter(([, ratio]) => ratio < 4.5);
    expect(failing, JSON.stringify(seen)).toEqual([]);
  });

  // One surface in two languages: the pages' blur, fallback tint and shadow are the native ones.
  test("the pages' tooltip surface matches TooltipSurface.swift", () => {
    const swift = fs.readFileSync(
      path.resolve(
        import.meta.dir,
        "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tooltip/TooltipSurface.swift",
      ),
      "utf8",
    );
    const value = (name: string) => Number(swift.match(new RegExp(`static let ${name}: Double = ([\\d.]+)`))![1]);
    const desktop = fs.readFileSync(path.join(source, "pages/shared/desktop.css"), "utf8");
    // The tooltip is the chip glass level (design-scale glass): its blur and fallback tint are the level's.
    expect(desktop).toContain("--tooltip-blur: var(--ds-glass-chip-blur);");
    expect(desktop).toContain(`--ds-glass-chip-blur: blur(${value("blurRadius")}px)`);
    expect(desktop).toContain(
      "--tooltip-tint: var(--cmux-tooltip-tint, color-mix(in srgb, var(--surface-popup) var(--ds-glass-chip-tint), transparent));",
    );
    expect(desktop).toContain(`--ds-glass-chip-tint: ${Math.round(value("minimumTintAlpha") * 100)}%;`);
    // The shadow is elevation 1 on both sides (TooltipSurface.shadow, --elevation-1).
    expect(swift).toContain("static var shadow: Elevation { PopupStyle.elevation1 }");
    expect(desktop).toContain("--tooltip-shadow: var(--elevation-1);");
  });
  // Lawrence 2026-11-20: one tooltip everywhere, on the composer's "Select effort ⌃⇧M". The page's
  // tooltip has the native one's shape (TooltipMetrics.swift): regular text at the detail size, one
  // height with or without keys, the keys on a keycap inset the same from the top, bottom and end with
  // its corner nested in the tooltip's, below its control.
  test("the tooltip's shape is TooltipMetrics.swift's: regular text, a keycap inset 4px, one height, below its control", async () => {
    const swift = fs.readFileSync(
      path.resolve(
        import.meta.dir,
        "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tooltip/TooltipMetrics.swift",
      ),
      "utf8",
    );
    const metric = (name: string) => Number(swift.match(new RegExp(`static let ${name}: CGFloat = ([\\d.]+)`))![1]);
    for (const scale of [1, 1.25]) {
      const page = await open(
        theme("dark", `--cmux-interface-scale:${scale};`),
        `<div style="display:flex;gap:40px;padding:40px">
           <button id="keyed" title="Select effort" data-tooltip-shortcut="⌃⇧M" style="width:28px;height:28px"></button>
           <button id="plain" title="Back" style="width:28px;height:28px"></button>
         </div>`,
      );
      try {
        const measure = async (id: string) => {
          await hoverAndWait(page, id);
          return page.evaluate((target) => {
            const tip = document.querySelector<HTMLElement>(".ui-title-tooltip")!;
            const rect = tip.getBoundingClientRect();
            const anchor = document.getElementById(target)!.getBoundingClientRect();
            const style = getComputedStyle(tip);
            const text = getComputedStyle(tip.querySelector(".ui-tooltip-text") ?? tip);
            const hint = tip.querySelector<HTMLElement>(".ui-tooltip-hint");
            const key = hint?.getBoundingClientRect();
            return {
              height: rect.height,
              below: rect.top - anchor.bottom,
              radius: parseFloat(style.borderTopLeftRadius),
              fontSize: parseFloat(text.fontSize),
              fontWeight: Number(text.fontWeight),
              key: key && {
                height: key.height,
                top: key.top - rect.top,
                bottom: rect.bottom - key.bottom,
                end: rect.right - key.right,
                radius: parseFloat(getComputedStyle(hint!).borderTopLeftRadius),
                fill: getComputedStyle(hint!).backgroundColor,
              },
            };
          }, id);
        };
        const keyed = await measure("keyed");
        await page.mouse.move(480, 290);
        await page.waitForFunction(() => document.querySelector<HTMLElement>(".ui-title-tooltip")!.hidden);
        const plain = await measure("plain");
        const height = (metric("lineHeight") + 2 * metric("paddingBlock")) * scale;
        const inset = metric("keycapInset") * scale;
        for (const seen of [keyed, plain]) {
          expect(Math.abs(seen.height - height)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(seen.below - metric("gap") * scale)).toBeLessThanOrEqual(0.5);
          expect(seen.radius).toBeCloseTo(metric("radius") * scale, 1);
          expect(seen.fontSize).toBeCloseTo(metric("fontSize") * scale, 1);
          expect(seen.fontWeight).toBe(400);
        }
        expect(plain.key).toBeUndefined();
        const key = keyed.key!;
        expect(key.height).toBeCloseTo(metric("keycapHeight") * scale, 1);
        // The rim is one device pixel inside the box; the plate's inset is from the box's edge.
        for (const side of [key.top, key.bottom, key.end]) expect(Math.abs(side - inset)).toBeLessThanOrEqual(1);
        expect(key.radius).toBeCloseTo((metric("radius") - metric("keycapInset")) * scale, 1);
        expect(key.fill).not.toBe("rgba(0, 0, 0, 0)");
      } finally {
        await page.close();
      }
    }
  });

  // A tooltip is one line, like the native one (Chief, 2026-11-21: "Make web tooltips one line, like
  // native"; TooltipContentView.swift): a long title ends in an ellipsis at the widest tooltip, a
  // title's second line never shows, and a detail line is gone (its words describe the control).
  test("a tooltip is one line: a long title ends in an ellipsis, and only its first line shows", async () => {
    const long = "Open the pull request for the payments service in a new tab beside this chat and keep it there";
    for (const scale of [1, 1.25]) {
      const page = await open(
        theme("dark", `--cmux-interface-scale:${scale};`),
        `<button id="wide" style="position:absolute;left:20px;top:150px;width:28px;height:28px" title="${long}"></button>` +
          '<button id="rows" style="position:absolute;left:80px;top:150px;width:28px;height:28px" title="Fork from here&#10;Start a new thread." data-tooltip-detail="This one stays as it is."></button>',
      );
      try {
        const seen = async (id: string) => {
          await hoverAndWait(page, id);
          return page.evaluate(() => {
            const tip = document.querySelector<HTMLElement>(".ui-title-tooltip")!;
            const text = tip.querySelector<HTMLElement>(".ui-tooltip-text")!;
            const style = getComputedStyle(tip);
            return {
              text: tip.textContent,
              width: tip.getBoundingClientRect().width,
              height: tip.getBoundingClientRect().height,
              line: parseFloat(style.lineHeight),
              padding: parseFloat(style.paddingTop) + parseFloat(style.paddingBottom),
              rim: parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth),
              cut: text.scrollWidth > text.clientWidth,
              ellipsis: getComputedStyle(text).textOverflow,
              details: tip.querySelectorAll(".ui-tooltip-detail").length,
            };
          });
        };
        const wide = await seen("wide");
        expect(wide.text).toBe(long);
        expect(wide.width).toBeLessThanOrEqual(320 * scale + 0.5);
        expect(Math.abs(wide.height - (wide.line + wide.padding + wide.rim))).toBeLessThanOrEqual(0.5);
        expect(wide.cut).toBe(true);
        expect(wide.ellipsis).toBe("ellipsis");
        await page.mouse.move(400, 280);
        await page.waitForFunction(() => document.querySelector<HTMLElement>(".ui-title-tooltip")!.hidden);
        const rows = await seen("rows");
        expect(rows.text).toBe("Fork from here");
        expect(rows.details).toBe(0);
        expect(Math.abs(rows.height - (rows.line + rows.padding + rows.rim))).toBeLessThanOrEqual(0.5);
      } finally {
        await page.close();
      }
    }
  });
});
