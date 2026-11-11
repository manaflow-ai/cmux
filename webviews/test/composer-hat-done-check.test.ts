// l10n-allow-file: the gallery fixture supplies the tasks and times this geometry contract measures.
// The composer hat's done check against the hat's other glyphs (Leo, 2026-11-08, on "47s ✓": "it's just
// bc the alignment/whatever around the rest of the hat when you look at the symbol and size/whatnot of
// it it just feels iffy how it's close the the number but idk if it should be so close"). The check is a
// status mark in the lines' Stop column: the Stop square's size, centred on the digits, one tray gap
// after the time's column, on a running, a finished and a failed line alike, and on the folded header
// of a lone finished item, where it sat 4px after its time, off the lines' columns. Gallery
// `agent-pane.composer-hat-done-check` (rows, lone). Prints each glyph's measurements as MEASURE lines.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Box = { left: number; right: number; top: number; bottom: number; width: number; height: number };

await requireBrowserLane("composer-hat-done-check.test.ts", async () => {
  const ENTRY = "agent-pane.composer-hat-done-check";

  /** Runs in the page: every glyph and column the check is judged against, in client px. */
  function measure() {
    const rect = (node: Element | null): Box | null => {
      if (!node) return null;
      const r = node.getBoundingClientRect();
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height };
    };
    const glyph = (svg: SVGSVGElement | null | undefined) => {
      if (!svg) return null;
      const ctm = svg.getScreenCTM();
      if (!ctm) return null;
      let x0 = Infinity;
      let y0 = Infinity;
      let x1 = -Infinity;
      let y1 = -Infinity;
      let stroke = 0;
      for (const shape of svg.querySelectorAll<SVGGraphicsElement>("path, rect, circle, line, polyline")) {
        const style = getComputedStyle(shape);
        if (style.display === "none" || style.visibility === "hidden") continue;
        const b = shape.getBBox();
        const width = style.stroke !== "none" ? parseFloat(style.strokeWidth) || 0 : 0;
        stroke = Math.max(stroke, width * ctm.a);
        const half = width / 2;
        x0 = Math.min(x0, ctm.e + (b.x - half) * ctm.a);
        x1 = Math.max(x1, ctm.e + (b.x + b.width + half) * ctm.a);
        y0 = Math.min(y0, ctm.f + (b.y - half) * ctm.d);
        y1 = Math.max(y1, ctm.f + (b.y + b.height + half) * ctm.d);
      }
      return {
        box: rect(svg)!,
        ink: { left: x0, right: x1, top: y0, bottom: y1, width: x1 - x0, height: y1 - y0 },
        stroke,
      };
    };
    /** The digits' cap line and baseline, so a glyph's centre can be read against the digits' centre. */
    const digits = (node: HTMLElement | null) => {
      if (!node || !node.textContent?.trim()) return null;
      const probe = document.createElement("span");
      probe.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline";
      node.append(probe);
      const baseline = probe.getBoundingClientRect().top;
      probe.remove();
      const style = getComputedStyle(node);
      const ctx = document.createElement("canvas").getContext("2d")!;
      ctx.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      const cap = ctx.measureText("0").actualBoundingBoxAscent;
      const range = document.createRange();
      range.selectNodeContents(node);
      const text = range.getBoundingClientRect();
      return { right: text.right, left: text.left, baseline, cap, center: baseline - cap / 2 };
    };
    const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
    const css = getComputedStyle(tray);
    const px = (name: string) => parseFloat(css.getPropertyValue(name));
    const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head");
    const headTime = head?.querySelector<HTMLElement>(".acpmux-running-tray__time[data-lone] .acpmux-done-mark__time");
    const rows = [...tray.querySelectorAll<HTMLElement>(".acpmux-agent-line")].map((line) => {
      const time = line.querySelector<HTMLElement>(".acpmux-agent-line__time");
      return {
        status: line.dataset.status ?? "",
        row: rect(line)!,
        leading: glyph(line.querySelector<SVGSVGElement>(".acpmux-lineage__icon svg")),
        stopTrack: rect(line.querySelector(".acpmux-agent-line__stop-track"))!,
        stop: glyph(line.querySelector<SVGSVGElement>(".acpmux-agent-line__stop-slot > button svg")),
        check: glyph(line.querySelector<SVGSVGElement>("[data-done-check] svg")),
        chevron: glyph(line.querySelector<SVGSVGElement>(".acpmux-agent-line__chevron svg")),
        time: rect(time),
        digits: digits(time),
      };
    });
    return {
      tray: rect(tray)!,
      tokens: {
        gap: px("--acpmux-tray-gap"),
        // The inset token is a calc(); the line's own padding is its resolved value.
        inset: parseFloat(
          getComputedStyle(tray.querySelector(".acpmux-agent-line__button") ?? head ?? tray).paddingRight,
        ),
        stop: px("--acpmux-tray-stop-width"),
        chevron: px("--acpmux-tray-chevron-width"),
      },
      head: head
        ? {
            row: rect(head)!,
            check: glyph(head.querySelector<SVGSVGElement>("[data-done-check] svg")),
            track: rect(head.querySelector("[data-done-check]")),
            chevron: glyph(head.querySelector<SVGSVGElement>(".acpmux-running-tray__chevron svg")),
            time: rect(headTime ?? null),
            digits: digits(headTime ?? null),
          }
        : null,
      rows,
    };
  }

  type Measured = ReturnType<typeof measure>;

  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "rows" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (variant: string, width: number, density: string, theme: string, arm?: string): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({
      viewport: { width, height: 420 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, density, colorScheme: theme, exp: arm && "composer-hat-done-check", arm })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  };
  const within = (actual: number, expected: number, what: string) => {
    if (!Number.isFinite(actual) || !Number.isFinite(expected) || Math.abs(actual - expected) > 0.5)
      throw new Error(`${what}: ${actual.toFixed(2)} vs ${expected.toFixed(2)}`);
  };
  const cx = (b: Box) => (b.left + b.right) / 2;
  const cy = (b: Box) => (b.top + b.bottom) / 2;
  /** Where a line's Stop column is centred, from the tray's own tokens: inset, chevron, gap, half a Stop. */
  const column = (m: Measured, right: number) =>
    right - m.tokens.inset - m.tokens.chevron - m.tokens.gap - m.tokens.stop / 2;

  for (const width of [760, 360])
    for (const density of ["comfortable", "compact"])
      for (const theme of ["light", "dark"]) {
        const name = `${width}px ${density} ${theme}`;

        test(`the done check stands in the lines' Stop column at the Stop square's size (${name})`, async () => {
          const page = await open("rows", width, density, theme);
          try {
            const m = await page.evaluate(measure);
            console.log(`MEASURE rows ${name} ${JSON.stringify(m)}`);
            const running = m.rows.find((row) => row.status === "running");
            const done = m.rows.find((row) => row.status === "done");
            const failed = m.rows.find((row) => row.status === "failed");
            if (!running?.stop || !done?.check || !failed)
              throw new Error("a running line with Stop, a done line with its check and a failed line");
            // One column across every line: its Stop track, its time's right edge.
            for (const row of [running, done, failed]) {
              within(row.stopTrack.left, running.stopTrack.left, `${row.status} Stop column left`);
              within(row.stopTrack.right, running.stopTrack.right, `${row.status} Stop column right`);
              within(row.time!.right, running.time!.right, `${row.status} time right`);
              within(cx(row.stopTrack), column(m, row.row.right), `${row.status} Stop column centre`);
            }
            // The check sits where the Stop square sits: the hat's icon size and stroke (a line's
            // chevron's), drawn on the full grid so its ink is no wider than the square and a stroke,
            // never the cropped row icon whose ink ran a third wider than the square.
            within(cx(done.check.box), cx(running.stop.box), "check centre x vs Stop");
            within(done.check.box.width, running.chevron!.box.width, "check box vs the hat's icon size");
            within(done.check.stroke, running.chevron!.stroke, "check stroke vs the chevron's");
            expect(done.check.ink.width).toBeLessThanOrEqual(running.stop.ink.width + 1.5);
            expect(done.check.ink.width).toBeGreaterThanOrEqual(running.stop.ink.width - 1.5);
            // Centred on the digits as the Stop square is.
            within(
              cy(done.check.ink) - cy(done.time!),
              cy(running.stop.ink) - cy(running.time!),
              "check ink centre vs Stop ink centre, each on its line's time",
            );
            within(cy(done.check.box), cy(done.time!), "check centre vs time centre");
            // One tray gap from the time's column to the check's column, the same as on a running line,
            // so the digits keep the same room before the check as before the Stop square.
            within(done.stopTrack.left - done.time!.right, m.tokens.gap, "time to check column gap");
            within(
              done.check.ink.left - done.digits!.right,
              running.stop.ink.left - running.digits!.right,
              "time-to-glyph ink gap vs running",
            );
          } finally {
            await page.close();
          }
        });

        test(`a lone finished item's check keeps a line's time-to-Stop rhythm on the folded header (${name})`, async () => {
          const rowsPage = await open("rows", width, density, theme);
          const lines = await rowsPage.evaluate(measure).finally(() => rowsPage.close());
          const running = lines.rows.find((row) => row.status === "running");
          if (!running?.stop || !running.chevron || !running.digits) throw new Error("a running line with Stop");
          const page = await open("lone", width, density, theme);
          try {
            const m = await page.evaluate(measure);
            console.log(`MEASURE lone ${name} ${JSON.stringify(m)}`);
            const head = m.head;
            if (!head?.check || !head.track || !head.time || !head.digits)
              throw new Error("a folded header with a time and a check");
            within(head.check.box.width, running.chevron!.box.width, "header check box vs the hat's icon size");
            expect(Math.abs(head.check.ink.width - running.stop.ink.width)).toBeLessThanOrEqual(1.5);
            // Its own Stop-wide column, one tray gap after the time, the check centred in it.
            within(head.track.width, m.tokens.stop, "header check column width");
            within(head.track.left - head.time.right, m.tokens.gap, "header time to check column gap");
            within(cx(head.check.box), cx(head.track), "header check centred in its column");
            within(
              head.check.ink.left - head.digits.right,
              running.stop.ink.left - running.digits.right,
              "header time-to-check ink gap vs a line's time-to-Stop",
            );
            within(cy(head.check.box), cy(head.time), "header check centre vs time centre");
          } finally {
            await page.close();
          }
        });

        test(`MEASURE the check-place arms on the folded header (${name})`, async () => {
          for (const arm of ["grid", "column", "leading"]) {
            const page = await open("lone", width, density, theme, arm);
            try {
              console.log(`MEASURE arm-${arm} ${name} ${JSON.stringify(await page.evaluate(measure))}`);
            } finally {
              await page.close();
            }
          }
        });
      }
});
