// Looks on public surfaces only (examples/looks, docs/cmux-next/look-addons.md; Leo, 2026-11-18: "make
// sure stuff is faithful + doesn't shift + we're able to get the stuff good using sdks and apis so ppl
// can/could have recreated and customized stuff to their liking"). Each look's agent-pane/theme.css goes
// to the real pane the way the host sends a person's file (`cmuxAcpmuxBridge.applyCustomization`, as
// AgentPaneCustomization.swift does), on a chat with a prompt, tool rows and a reply. Then:
//   - faithful: each token the look sets reaches the element it names (the bubble's corner, a link);
//   - no shift: applying the look, reloading it and switching to another moves no box at all (the
//     contract is paint only, schemas/agent-pane/style-tokens.json);
//   - twin: a look whose built-in preset exists (looks.json `builtIn.variant`) draws within a few
//     pixels of it, so the built-in look never needs code an outsider cannot reach.
// Captures go to $FAST_CHECKS_OUT/look-addons when it is set.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("look-addons.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "../..");
  const repo = path.join(webviews, "..");
  type Look = { id: string; addon: string | null; builtIn: { variant?: string; maxMismatch?: number } | null };
  const looks = (JSON.parse(readFileSync(path.join(repo, "examples/looks/looks.json"), "utf8")) as { looks: Look[] })
    .looks;
  const addons = looks.filter((look): look is Look & { addon: string } => look.addon !== null);
  const css = (addon: string) => readFileSync(path.join(repo, "examples/looks", addon, "agent-pane/theme.css"), "utf8");
  const ENTRY = "agent-pane.transcript";
  const VARIANT = "activity-tone-secondary";
  const out = process.env.FAST_CHECKS_OUT ? path.join(process.env.FAST_CHECKS_OUT, "look-addons") : null;
  if (out) mkdirSync(out, { recursive: true });

  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );

  async function open(page: Page, variant: string, theme: "light" | "dark") {
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, {
        variant,
        theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        colorScheme: theme,
      })}`,
    );
    await page.locator(".cv-user__bubble").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await settle(page);
  }

  /** The host's path for a person's agent-pane/theme.css, over what the stage already sent (its font). */
  async function applyLook(page: Page, look: string) {
    await page.evaluate((look) => {
      const stage =
        (window as { __lookAddonsBase?: string }).__lookAddonsBase ??
        document.getElementById("acpmux-user-theme")?.textContent ??
        "";
      (window as { __lookAddonsBase?: string }).__lookAddonsBase = stage;
      (
        window as unknown as { cmuxAcpmuxBridge: { applyCustomization(c: { themeCSS: string }): void } }
      ).cmuxAcpmuxBridge.applyCustomization({ themeCSS: `${stage}\n${look}` });
    }, look);
    await settle(page);
  }

  /** Every drawn element's box, in document order. */
  const boxes = (page: Page) =>
    page.evaluate(() =>
      [...document.body.querySelectorAll("*")]
        .map((el) => {
          const r = el.getBoundingClientRect();
          return r.width || r.height
            ? {
                el: `${el.tagName.toLowerCase()}.${[...el.classList].join(".")}`,
                x: r.x,
                y: r.y,
                w: r.width,
                h: r.height,
              }
            : null;
        })
        .filter((box) => box !== null),
    );

  function moved(before: Awaited<ReturnType<typeof boxes>>, after: Awaited<ReturnType<typeof boxes>>): string[] {
    expect(after.length).toBe(before.length);
    const moves: string[] = [];
    before.forEach((a, index) => {
      const b = after[index]!;
      const delta = Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.w - b.w), Math.abs(a.h - b.h));
      if (delta > 0.5) moves.push(`${a.el}: ${JSON.stringify(a)} -> ${JSON.stringify(b)}`);
    });
    return moves;
  }

  for (const look of addons) {
    for (const theme of ["dark", "light"] as const) {
      test(`${look.id} (${theme}): applies through the host's path, faithful, and moves no box`, async () => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
        try {
          await open(page, VARIANT, theme);
          const plain = await boxes(page);
          const lookCss = css(look.addon);
          await applyLook(page, lookCss);
          expect(moved(plain, await boxes(page))).toEqual([]);

          // Faithful: every token the look sets is the value the page resolves on :root, and the
          // bubble's corner is the one the look names.
          const set = [...lookCss.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map(
            (m) => [m[1]!, m[2]!.trim()] as const,
          );
          // A color resolves through a probe both ways (the page's token and the look's own text), since
          // a token's computed text substitutes the theme colors it mixes.
          const resolved = await page.evaluate((pairs) => {
            const color = (value: string) => {
              const el = document.createElement("div");
              el.style.color = value;
              document.body.append(el);
              const out = getComputedStyle(el).color;
              el.remove();
              return out;
            };
            return pairs.map(([name, value]) =>
              name.endsWith("-radius")
                ? [getComputedStyle(document.documentElement).getPropertyValue(name).trim(), value]
                : [color(`var(${name})`), color(value)],
            );
          }, set);
          for (const [name, [got, want]] of set.map(([name], index) => [name, resolved[index]!] as const))
            expect(got, name).toBe(want!);
          const radius = set.find(([name]) => name === "--cv-user-bubble-radius")?.[1];
          if (radius)
            expect(
              await page.evaluate(
                () => getComputedStyle(document.querySelector(".cv-user__bubble")!).borderTopLeftRadius,
              ),
            ).toBe(radius);
          if (out) writeFileSync(path.join(out, `${look.id}-${theme}.png`), await page.screenshot());

          // Hot reload: the same file saved again, then every other look, then back: nothing moves.
          const applied = await boxes(page);
          await applyLook(page, lookCss);
          expect(moved(applied, await boxes(page))).toEqual([]);
          for (const other of addons.filter((o) => o.id !== look.id)) {
            await applyLook(page, css(other.addon));
            expect(moved(applied, await boxes(page))).toEqual([]);
          }
          await applyLook(page, "");
          expect(moved(plain, await boxes(page))).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }
  }

  /** A look's theme file, comments dropped: its terminal theme pair and its per-theme edits. */
  function lookTheme(addon: string): { light: string; dark: string; edits: Record<string, string> } {
    const text = readFileSync(path.join(repo, "examples/looks", addon, "themes", `${addon}.json`), "utf8");
    const file = JSON.parse(text.replace(/^\s*\/\/.*$/gm, "")) as Record<string, unknown>;
    const spec = String(file["appearance.theme"]);
    const side = (name: "light" | "dark") => new RegExp(`${name}:([^,]+)`).exec(spec)?.[1]?.trim() ?? spec;
    return {
      light: side("light"),
      dark: side("dark"),
      edits: (file["appearance.themeEdits"] ?? {}) as Record<string, string>,
    };
  }

  /** The look on its own colors in one appearance: its theme there with the file's edits. */
  async function openLook(page: Page, addon: string, theme: "light" | "dark") {
    const own = lookTheme(addon);
    const name = own[theme];
    const edits = Object.entries(own.edits)
      .filter(([key]) => key.startsWith(`${name}/`))
      .map(([key, color]) => `${key.slice(name.length + 1)}:${color}`)
      .join(",");
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, theme: name, colorScheme: theme, themeEdits: edits })}`,
    );
    await page.locator(".cv-user__bubble").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await settle(page);
  }

  // WCAG 2.2 1.4.3: text at least 4.5:1 on what it sits on, in both appearances, for every look. Each
  // pair is a text token over a fill token over the page (the fill may be translucent).
  const MINIMUM = 4.5;
  const PAIRS: Array<[text: string, fill: string | null]> = [
    ["--cv-text", null],
    ["--cv-text-muted", null],
    ["--cv-text-dim", null],
    ["--cv-link", null],
    ["--agent-link", null],
    ["--cv-text-muted", "--cv-card-fill"],
    ["--cv-link", "--cv-card-fill"],
    ["--cv-codeblock-text", "--cv-codeblock-bg"],
    ["--cv-text", "--cv-user-bubble-tint"],
  ];
  for (const look of addons) {
    for (const theme of ["light", "dark"] as const) {
      test(`${look.id} (${theme}): every text token reads at ${MINIMUM}:1 on its own colors`, async () => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
        try {
          await openLook(page, look.addon, theme);
          await applyLook(page, css(look.addon));
          const ratios = await page.evaluate((pairs) => {
            const probe = (style: string) => {
              const el = document.createElement("div");
              el.setAttribute("style", style);
              document.body.append(el);
              const out = getComputedStyle(el).color;
              el.remove();
              return out;
            };
            /** `rgb(...)`, `rgba(...)` or `color(srgb ...)` as [r, g, b, a] in 0..1. */
            const parse = (text: string): number[] => {
              const nums = (text.match(/-?[\d.]+(?:e-?\d+)?%?/g) ?? []).map((n) =>
                n.endsWith("%") ? Number(n.slice(0, -1)) / 100 : Number(n),
              );
              const srgb = text.startsWith("color(");
              const [r = 0, g = 0, b = 0] = srgb ? nums : nums.map((n) => n / 255);
              return [r, g, b, nums[3] ?? 1];
            };
            const over = (top: number[], under: number[]) =>
              [0, 1, 2].map((i) => top[i]! * top[3]! + under[i]! * (1 - top[3]!)).concat(1);
            const luminance = (c: number[]) =>
              [0, 1, 2]
                .map((i) => (c[i]! <= 0.04045 ? c[i]! / 12.92 : ((c[i]! + 0.055) / 1.055) ** 2.4))
                .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i]!, 0);
            const page = parse(probe("color: var(--agent-page-bg)"));
            const base = page[3]! < 1 ? over(page, parse(getComputedStyle(document.body).backgroundColor)) : page;
            return pairs.map(([text, fill]) => {
              const ground = fill ? over(parse(probe(`color: var(${fill})`)), base) : base;
              const ink = over(parse(probe(`color: var(${text})`)), ground);
              const [hi, lo] = [luminance(ink), luminance(ground)].sort((a, b) => b - a);
              return `${text} on ${fill ?? "page"}: ${((hi! + 0.05) / (lo! + 0.05)).toFixed(2)}`;
            });
          }, PAIRS);
          const low = ratios.filter((line) => Number(line.split(": ")[1]) < MINIMUM);
          expect(low, ratios.join("\n")).toEqual([]);
          if (out) writeFileSync(path.join(out, `${look.id}-own-${theme}.png`), await page.screenshot());
        } finally {
          await page.close();
        }
      });
    }
  }

  for (const look of addons.filter((look) => look.builtIn?.variant)) {
    test(`${look.id}: the add-on draws the built-in preset (${look.builtIn!.variant})`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
      try {
        await open(page, look.builtIn!.variant!, "dark");
        const builtIn = PNG.sync.read(await page.screenshot());
        await open(page, VARIANT, "dark");
        await applyLook(page, css(look.addon));
        const addon = PNG.sync.read(await page.screenshot());
        const diff = new PNG({ width: builtIn.width, height: builtIn.height });
        const mismatch = pixelmatch(builtIn.data, addon.data, diff.data, builtIn.width, builtIn.height, {
          threshold: 0.1,
        });
        if (out) writeFileSync(path.join(out, `${look.id}-twin-diff.png`), PNG.sync.write(diff));
        expect(mismatch / (builtIn.width * builtIn.height)).toBeLessThanOrEqual(look.builtIn!.maxMismatch ?? 0.002);
      } finally {
        await page.close();
      }
    });
  }
});
