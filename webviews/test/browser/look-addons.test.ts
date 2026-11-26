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
//   - readable: in light and in dark, every drawn line of text keeps WCAG AA contrast over what is
//     under it (4.5:1, 3:1 for large text), computed from the colors the page resolves and the fills
//     it stacks under the text. A line the plain chat already draws under the minimum may not get
//     worse. Studio 1.0.0 (2.9:1 bubble in light) and Paper 1.0.0 (1.4:1 bubble in dark) fail it
//     (cmux#46049); scripts/check-look-addons.ts refuses the literal colors that caused them.
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

  async function open(page: Page, variant: string, theme: "light" | "dark", accent?: "blue") {
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, {
        variant,
        theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        colorScheme: theme,
        accent,
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

  type Line = { key: string; text: string; ratio: number; min: number };
  /** Every element that draws text of its own: its contrast over the fills stacked under it. */
  const readability = (page: Page) =>
    page.evaluate((): Line[] => {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
      type Rgba = [number, number, number, number];
      const parse = (css: string): Rgba => {
        const srgb = /^color\(srgb ([-\d.e]+) ([-\d.e]+) ([-\d.e]+)(?: \/ ([\d.e]+))?\)$/.exec(css);
        if (srgb) return [+srgb[1]!, +srgb[2]!, +srgb[3]!, srgb[4] === undefined ? 1 : +srgb[4]];
        const rgb = /^rgba?\(([\d.]+), ([\d.]+), ([\d.]+)(?:, ([\d.]+))?\)$/.exec(css);
        if (rgb) return [+rgb[1]! / 255, +rgb[2]! / 255, +rgb[3]! / 255, rgb[4] === undefined ? 1 : +rgb[4]];
        // oklab(), lab() and the rest: the canvas converts them.
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
        const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
        return [r! / 255, g! / 255, b! / 255, a! / 255];
      };
      const over = (top: Rgba, under: [number, number, number]): [number, number, number] => [
        top[0] * top[3] + under[0] * (1 - top[3]),
        top[1] * top[3] + under[1] * (1 - top[3]),
        top[2] * top[3] + under[2] * (1 - top[3]),
      ];
      const luminance = (c: [number, number, number]) => {
        const f = (v: number) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
      };
      const lines: Line[] = [];
      // Shadow roots too: Pierre draws a code card's lines in one.
      const all: Element[] = [];
      const walk = (root: ParentNode) => {
        for (const el of root.querySelectorAll("*")) {
          all.push(el);
          if (el.shadowRoot) walk(el.shadowRoot);
        }
      };
      walk(document.body);
      const parentOf = (node: Element): Element | null =>
        node.parentElement ?? ((node.getRootNode() as ShadowRoot).host as Element | undefined) ?? null;
      all.forEach((el, index) => {
        const own = [...el.childNodes]
          .filter((node) => node.nodeType === Node.TEXT_NODE)
          .map((node) => node.textContent ?? "")
          .join("")
          .trim();
        if (!own || el.closest("[disabled], [aria-disabled='true'], [inert]")) return;
        const box = el.getBoundingClientRect();
        if (!box.width || !box.height) return;
        const style = getComputedStyle(el);
        if (style.visibility !== "visible" || style.display === "none") return;
        // The fills under the text, outermost first, and the opacity the text is drawn at.
        const fills: Rgba[] = [];
        let opacity = 1;
        for (let node: Element | null = el; node; node = parentOf(node)) {
          const s = getComputedStyle(node);
          opacity *= +s.opacity;
          fills.unshift(parse(s.backgroundColor));
        }
        if (opacity < 0.05) return;
        let under: [number, number, number] = [1, 1, 1];
        const firstOpaque = fills.findIndex((fill) => fill[3] >= 0.999);
        if (firstOpaque < 0) {
          const pageBg = parse(
            getComputedStyle(document.documentElement).getPropertyValue("--agent-page-bg").trim() || "#fff",
          );
          under = [pageBg[0], pageBg[1], pageBg[2]];
        }
        for (const fill of fills.slice(Math.max(0, firstOpaque))) under = over(fill, under);
        const ink = parse(style.color);
        const text = over([ink[0], ink[1], ink[2], ink[3] * opacity], under);
        const [hi, lo] = [luminance(text), luminance(under)].sort((a, b) => b - a);
        const size = parseFloat(style.fontSize);
        const large = size >= 24 || (size >= 18.66 && +style.fontWeight >= 700);
        lines.push({
          key: `${index} ${el.tagName.toLowerCase()}.${[...el.classList].join(".")}`,
          text: own.slice(0, 40),
          ratio: Math.round(((hi! + 0.05) / (lo! + 0.05)) * 100) / 100,
          min: large ? 3 : 4.5,
        });
      });
      return lines;
    });

  /** The lines a look draws under the minimum where the plain chat did not, or lower than it did. */
  function unreadable(plain: Line[], looked: Line[]): string[] {
    const before = new Map(plain.map((line) => [line.key, line.ratio]));
    return looked
      .filter((line) => line.ratio < line.min && line.ratio < (before.get(line.key) ?? Infinity) - 0.05)
      .map(
        (line) => `${line.key} "${line.text}": ${line.ratio}:1 (needs ${line.min}:1; plain ${before.get(line.key)}:1)`,
      );
  }

  for (const look of addons) {
    for (const theme of ["dark", "light"] as const) {
      test(`${look.id} (${theme}): applies through the host's path, faithful, and moves no box`, async () => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
        try {
          await open(page, VARIANT, theme);
          const plain = await boxes(page);
          const plainLines = await readability(page);
          const lookCss = css(look.addon);
          await applyLook(page, lookCss);
          expect(moved(plain, await boxes(page))).toEqual([]);

          // Readable in this appearance: no line under WCAG AA that the plain chat drew above it.
          const lookLines = await readability(page);
          // The fixture's prompt, tool rows, reply and code: each kind is read.
          expect(lookLines.length).toBeGreaterThanOrEqual(8);
          // The lowest line of each look, in the log (a fleet run keeps no files).
          const lowest = [...lookLines].sort((a, b) => a.ratio - b.ratio).slice(0, 3);
          console.log(
            `look-addons contrast ${look.id} ${theme}: ${lookLines.length} lines; lowest ${lowest
              .map((line) => `${line.ratio}:1 ${line.key.replace(/^\d+ /, "")} "${line.text}"`)
              .join(" | ")}`,
          );
          if (out)
            writeFileSync(
              path.join(out, `${look.id}-${theme}-contrast.json`),
              JSON.stringify({ plain: plainLines, look: lookLines }, null, 1),
            );
          expect(unreadable(plainLines, lookLines)).toEqual([]);

          // Faithful: every token the look sets is the value the page resolves on :root, and the
          // bubble's corner is the one the look names. A token built from the theme's own vars
          // (var(--agent-text)) resolves with them substituted, so the look's value is resolved
          // the same way, on a probe under :root, and the two are compared resolved.
          const set = [...lookCss.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map(
            (m) => [m[1]!, m[2]!.trim()] as const,
          );
          const [resolved, declared] = await page.evaluate(
            (pairs) => {
              const probe = document.createElement("div");
              document.documentElement.appendChild(probe);
              try {
                const declared = pairs.map(([, value]) => {
                  probe.style.setProperty("--look-probe", value);
                  return getComputedStyle(probe).getPropertyValue("--look-probe").trim();
                });
                const resolved = pairs.map(([name]) =>
                  getComputedStyle(document.documentElement).getPropertyValue(name).trim(),
                );
                return [resolved, declared];
              } finally {
                probe.remove();
              }
            },
            set as unknown as [string, string][],
          );
          expect(resolved).toEqual(declared);
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

  // The detector: the looks as published at 1.0.0, each written for one appearance, fail over the other.
  const LITERAL_LOOKS = {
    "studio 1.0.0 over light": [
      "light",
      ":root { --cv-user-bubble-tint: rgb(39 39 42 / 0.72); --cv-user-bubble-edge: rgb(63 63 70 / 0.9); --cv-card-fill: rgb(24 24 27 / 0.9); --cv-text-muted: #a1a1aa; --cv-text-dim: #71717a; --cv-link: #93c5fd; --agent-link: #93c5fd; }",
    ],
    "paper 1.0.0 over dark": [
      "dark",
      ":root { --cv-user-bubble-tint: rgb(232 225 211 / 0.85); --cv-card-fill: rgb(244 239 229 / 0.9); --cv-text-muted: #6b6257; --cv-text-dim: #948a7d; --cv-link: #8a5a2b; --agent-link: #8a5a2b; }",
    ],
  } as const;
  for (const [name, [theme, lookCss]] of Object.entries(LITERAL_LOOKS)) {
    test(`a look written for one appearance fails the contrast check over the other (${name})`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
      try {
        await open(page, VARIANT, theme);
        const plainLines = await readability(page);
        await applyLook(page, lookCss);
        expect(unreadable(plainLines, await readability(page)).length).toBeGreaterThan(0);
      } finally {
        await page.close();
      }
    });
  }

  // The bubble's ink (--cv-user-bubble-text): a filled pill, as Codex draws its prompt (white on blue),
  // made from the theme's own colors. It must land on the bubble and on its quiet lines, move no box,
  // and stay readable in both appearances; the same fill without the ink, or the ink over a pale
  // fill, must fail the contrast check, so the check guards the token and not only the tint.
  const PILL_TINT =
    "--cv-user-bubble-tint: light-dark(color-mix(in srgb, var(--agent-accent) 78%, var(--agent-text)), color-mix(in srgb, var(--agent-accent) 30%, var(--agent-page-bg)));";
  const PILL_INK = "--cv-user-bubble-text: light-dark(var(--agent-page-bg), var(--agent-text));";
  // Over a blue accent (the pill Codex draws) and over the neutral one, where the theme's accent is
  // its own text color, so the pill's mix must still leave room for the ink.
  for (const [theme, accent] of [
    ["dark", "blue"],
    ["light", "blue"],
    ["dark", undefined],
    ["light", undefined],
  ] as const) {
    test(`a filled pill with its own ink (${theme}, ${accent ?? "neutral"} accent): lands, moves no box, reads`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
      try {
        // The bubble-ink arm: its first prompt is Markdown (a quote, inline code), its second plain text.
        await open(page, "user-bubble-ink-default", theme, accent);
        const plain = await boxes(page);
        const plainLines = await readability(page);
        await applyLook(page, `:root { ${PILL_TINT} ${PILL_INK} }`);
        expect(moved(plain, await boxes(page))).toEqual([]);
        expect(unreadable(plainLines, await readability(page))).toEqual([]);
        const [ink, wanted, bubbleBg] = await page.evaluate(() => {
          const probe = document.createElement("div");
          probe.style.color = "light-dark(var(--agent-page-bg), var(--agent-text))";
          document.documentElement.appendChild(probe);
          const wanted = getComputedStyle(probe).color;
          probe.remove();
          const bubble = document.querySelector(".cv-user__bubble")!;
          return [getComputedStyle(bubble).color, wanted, getComputedStyle(bubble).backgroundColor];
        });
        expect(ink).toBe(wanted);
        // The fill is the pill's, opaque: no glass grey under the ink.
        expect(bubbleBg).not.toBe("rgba(0, 0, 0, 0)");
        if (out) writeFileSync(path.join(out, `pill-${theme}-${accent ?? "neutral"}.png`), await page.screenshot());
        // Unset again: the bubble draws exactly what it did.
        await applyLook(page, "");
        expect(moved(plain, await boxes(page))).toEqual([]);
        expect(await page.evaluate(() => getComputedStyle(document.querySelector(".cv-user__bubble")!).color)).toBe(
          await page.evaluate(() => {
            const probe = document.createElement("div");
            probe.style.color = "var(--cv-text)";
            document.documentElement.appendChild(probe);
            const color = getComputedStyle(probe).color;
            probe.remove();
            return color;
          }),
        );
      } finally {
        await page.close();
      }
    });
  }
  const INK_DETECTORS = {
    "a dark pill without its ink, over light": ["light", `:root { ${PILL_TINT} }`],
    "light ink on a pale tint, over light": [
      "light",
      ":root { --cv-user-bubble-tint: color-mix(in srgb, var(--agent-accent) 12%, transparent); --cv-user-bubble-text: var(--agent-page-bg); }",
    ],
  } as const;
  for (const [name, [theme, lookCss]] of Object.entries(INK_DETECTORS)) {
    test(`the contrast check catches a bubble ink that does not fit its fill (${name})`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
      try {
        await open(page, VARIANT, theme);
        const plainLines = await readability(page);
        await applyLook(page, lookCss);
        expect(unreadable(plainLines, await readability(page)).length).toBeGreaterThan(0);
      } finally {
        await page.close();
      }
    });
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
