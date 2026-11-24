// cmux-web-test-timeout: 600
// Every icon-only button keeps its glyph's ink centred in its box, and a code card's corner glyphs
// sit on its first line's centre (Leo, 2026-11-22, on a code card's Wrap and Copy riding above the
// code line: "this is off centered. we cant be having icons off centered"). Flex centring places
// the svg box in its button; this measures the drawn ink (each shape's getBBox() through its
// getScreenCTM()) against the button's getBoundingClientRect(), in light and dark, across the
// button families of the agent pane: code-block toolbars, the composer and its hat, the chat
// header's tools, tab rows, the sidebar, tool rows and menus. Handbook: icon-glyphs-off-center.md.
// ICON_CENTER_REPORT=1 prints every measurement (the PR's offsets table).
import { expect, test } from "bun:test";
import { chromium } from "playwright";
import { createServer } from "vite";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("icon-button-centers.test.ts", async () => {
  /// The detector's contract: the ink centre within this many CSS px of its box's centre.
  const TOLERANCE = 0.5;

  type Measure = {
    kind: "glyph" | "line";
    where: string;
    icon: string;
    dx: number;
    dy: number;
  };

  /// Entries and variants that draw each family's icon buttons.
  const CASES: { id: string; variant?: string }[] = [
    { id: "agent-pane.code-toolbar-buttons", variant: "code" },
    { id: "agent-pane.code-toolbar-buttons", variant: "diff" },
    { id: "agent-pane.code-toolbar-buttons", variant: "output" },
    { id: "agent-pane.code-toolbar-buttons", variant: "table" },
    { id: "agent-pane.code-toolbar-buttons", variant: "highlighted-rest" },
    { id: "agent-pane.code-block-diagram" },
    { id: "agent-pane.table-block" },
    { id: "agent-pane.composer" },
    { id: "agent-pane.composer-toolbar-buttons" },
    { id: "agent-pane.composer-hat" },
    { id: "agent-pane.header-tools" },
    { id: "agent-pane.header-controls-trio" },
    { id: "agent-pane.glass-toolbar" },
    { id: "agent-pane.toolbar-icons" },
    { id: "agent-pane.tab-row-slot" },
    { id: "agent-pane.tool-row-column" },
    { id: "agent-pane.claude-code-tool-rows" },
    { id: "agent-pane.chat-find-bar" },
    { id: "agent-pane.options-menu" },
    { id: "agent-pane.transcript-view-menu" },
    { id: "sidebar.all-chats" },
    { id: "pages.sidebar-chats" },
    { id: "ui.toolbar" },
    { id: "ui.tabs" },
    { id: "ui.menu" },
  ];

  /// Runs in the page: every visible icon-only button's ink offset, and each corner glyph's offset
  /// from its card's first line.
  function measurePage(): Measure[] {
    const out: Measure[] = [];
    const SHAPES = "path, rect, circle, ellipse, line, polyline, polygon";
    const describe = (el: Element) => {
      const label = el.getAttribute("aria-label") ?? el.getAttribute("title") ?? "";
      const cls =
        typeof el.className === "string" ? el.className.split(/\s+/).filter(Boolean).slice(0, 2).join(".") : "";
      return `${el.tagName.toLowerCase()}${cls ? `.${cls}` : ""}${label ? `[${label}]` : ""}`;
    };
    const ink = (svg: SVGSVGElement) => {
      let x0 = Infinity,
        y0 = Infinity,
        x1 = -Infinity,
        y1 = -Infinity;
      const shapes = svg.querySelectorAll<SVGGraphicsElement>(SHAPES);
      for (const shape of shapes) {
        if (shape.closest("defs, mask, clipPath, symbol")) continue;
        const style = getComputedStyle(shape);
        if (style.display === "none" || style.visibility === "hidden") continue;
        if (style.fill === "none" && style.stroke === "none") continue;
        const box = shape.getBBox();
        const m = shape.getScreenCTM();
        if (!m || (box.width === 0 && box.height === 0)) continue;
        for (const [x, y] of [
          [box.x, box.y],
          [box.x + box.width, box.y],
          [box.x, box.y + box.height],
          [box.x + box.width, box.y + box.height],
        ]) {
          const px = m.a * x + m.c * y + m.e;
          const py = m.b * x + m.d * y + m.f;
          x0 = Math.min(x0, px);
          y0 = Math.min(y0, py);
          x1 = Math.max(x1, px);
          y1 = Math.max(y1, py);
        }
      }
      return Number.isFinite(x0) ? { cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 } : null;
    };
    for (const button of document.querySelectorAll<HTMLElement>("button, [role='button']")) {
      const svgs = [...button.querySelectorAll<SVGSVGElement>("svg")].filter((svg) => !svg.closest("svg svg"));
      if (svgs.length !== 1) continue;
      if ((button.textContent ?? "").trim() !== "") continue;
      // The box the glyph is drawn in: the innermost painted box between the glyph and its button (a
      // pill inside a wider hit strip, like the composer hat's pull tab), else the button itself.
      let boxEl: Element = button;
      for (let el = svgs[0]!.parentElement; el && el !== button; el = el.parentElement) {
        const style = getComputedStyle(el);
        const painted =
          (style.backgroundColor !== "rgba(0, 0, 0, 0)" && style.backgroundColor !== "transparent") ||
          style.boxShadow !== "none" ||
          parseFloat(style.borderTopWidth) > 0;
        if (painted) {
          boxEl = el;
          break;
        }
      }
      const rect = boxEl.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) continue;
      // An icon-only button that is wider than tall is a pill with padding (a chip, a picker's
      // caret): only its vertical centre is the glyph's.
      const square = Math.abs(rect.width - rect.height) <= 1;
      const centre = ink(svgs[0]!);
      if (!centre) continue;
      const icon = svgs[0]!.getAttribute("data-icon") ?? "svg";
      out.push({
        kind: "glyph",
        where: describe(button),
        icon,
        dx: square ? centre.cx - (rect.left + rect.width / 2) : 0,
        dy: centre.cy - (rect.top + rect.height / 2),
      });
    }
    // A code card's corner glyphs float over its first line: their centre is that line's centre.
    for (const card of document.querySelectorAll<HTMLElement>(".cv-codeblock--corner")) {
      const line =
        card.querySelector<HTMLElement>(".cv-code-plain__line") ??
        card.querySelector<HTMLElement>(".cv-codeblock__body")?.shadowRoot?.querySelector<HTMLElement>("[data-line]") ??
        null;
      if (!line) continue;
      const lr = line.getBoundingClientRect();
      for (const button of card.querySelectorAll<HTMLElement>(".cv-codeblock__actions > button")) {
        const br = button.getBoundingClientRect();
        out.push({
          kind: "line",
          where: `corner ${describe(button)}`,
          icon: button.querySelector("svg")?.getAttribute("data-icon") ?? "svg",
          dx: 0,
          dy: br.top + br.height / 2 - (lr.top + lr.height / 2),
        });
      }
    }
    return out;
  }

  test("icon buttons keep glyph ink centered in every family", async () => {
    const root = path.resolve(import.meta.dir, "../..");
    const vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    const browser = await chromium.launch();
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await warmGalleryFrame(vite, [...new Set(CASES.map(({ id }) => id))], {
        browser,
        timeoutMs: 240_000,
      });
      const failures: string[] = [];
      const rows: string[] = [];
      let measured = 0;
      for (const colorScheme of ["light", "dark"] as const)
        for (const entry of CASES) {
          const page = await browser.newPage({
            viewport: { width: 1000, height: 900 },
            colorScheme,
          });
          const family = `${entry.id}#${entry.variant ?? "default"}`;
          try {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(entry.id, { colorScheme, reducedMotion: "true", variant: entry.variant })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", null, {
              timeout: 60_000,
            });
            const found = (await page.evaluate(measurePage)) as Measure[];
            measured += found.length;
            for (const m of found) {
              const off = Math.abs(m.dx) > TOLERANCE || Math.abs(m.dy) > TOLERANCE;
              if (colorScheme === "dark")
                rows.push(
                  `| ${family} | ${m.kind} | ${m.where} | ${m.icon} | ${m.dx.toFixed(2)} | ${m.dy.toFixed(2)} |`,
                );
              if (off)
                failures.push(
                  `${colorScheme} ${family} ${m.kind} ${m.where} ${m.icon}: off by ${m.dx.toFixed(2)}, ${m.dy.toFixed(2)} px`,
                );
            }
          } finally {
            await page.close();
          }
        }
      if (process.env.ICON_CENTER_REPORT) console.log(rows.join("\n"));
      console.log(`Icon centre audit: ${measured} icon buttons measured in light and dark.`);
      expect(failures).toEqual([]);
      expect(measured).toBeGreaterThan(0);
    } finally {
      await browser.close();
      await vite.close();
    }
  }, 600_000);
});
