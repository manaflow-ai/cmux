// Real transcript components and CSS (test/browser/transcript-glyph-alignment.harness.tsx); all
// displayed content is synthetic.
//
// The message action rows (a prompt's, another agent's message's, a failed turn's footer) are one
// row of equal controls (Leo, 2026-10-27: "why is the copy button and the refresh button so far
// apart? Also, is this, like, your custom refresh button or something? ... this is not a, you know,
// evenly spaced, compact, unified, concise, simple, well-placed thing"; 2026-10-29: "this is still
// not aligned? :("). grid.md 5.5, action row: every control is one slot holding a 16 glyph box,
// the slots abut (one pitch, the Retry model chevron included), every glyph's ink centres on the
// row's one mid, the chevron's ink centres in its box, the age's last glyph ends 8 before the first
// glyph box, and Retry is the icon pack's arrow.clockwise (`action.reload`), not a hand-drawn one.
// Measured idle and with the chevron hovered and its menu open: showing state moves nothing.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Control = {
  left: number;
  width: number;
  cx: number;
  cy: number;
  glyphCx: number;
  glyphCy: number;
  glyphW: number;
  glyphH: number;
  inkCx: number;
  inkCy: number;
  chevron: boolean;
  paths: string[];
};
type Row = { kind: string; controls: Control[]; timeGap: number | null };

const webviews = path.resolve(import.meta.dir, "..");
const pack = JSON.parse(
  readFileSync(path.join(webviews, "src/agent-session/acpmux/icons/cmuxIcons.json"), "utf8"),
) as { icons: Record<string, { line: { d: string }[] }> };
const reload = pack.icons["action.reload"]!.line.map((layer) => layer.d);
const TOLERANCE = 0.5;

async function measure(page: Page): Promise<Row[]> {
  return page.evaluate(() => {
    const rows: [string, string, string | null][] = [
      ["prompt", "[data-footer-row] .cv-user__actions", "[data-footer-row] .cv-user__time"],
      [
        "received",
        '[data-received-row="retryable"] .cv-received-actions',
        '[data-received-row="retryable"] .cv-user__time',
      ],
      ["turn", '[data-action-row="turn"] .cv-turn-action-group', null],
    ];
    const visible = (el: Element) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== "none";
    };
    // The ink: the union of the glyph's shapes' geometry, in the page's coordinates.
    const ink = (svg: SVGSVGElement) => {
      let x0 = Infinity;
      let y0 = Infinity;
      let x1 = -Infinity;
      let y1 = -Infinity;
      for (const shape of svg.querySelectorAll<SVGGraphicsElement>("path, rect, circle, line, polyline")) {
        const box = shape.getBBox();
        const m = shape.getScreenCTM()!;
        for (const [x, y] of [
          [box.x, box.y],
          [box.x + box.width, box.y + box.height],
        ] as const) {
          const p = new DOMPoint(x, y).matrixTransform(m);
          x0 = Math.min(x0, p.x);
          y0 = Math.min(y0, p.y);
          x1 = Math.max(x1, p.x);
          y1 = Math.max(y1, p.y);
        }
      }
      return { cx: (x0 + x1) / 2, cy: (y0 + y1) / 2 };
    };
    return rows.map(([kind, selector, time]) => {
      const scope = document.querySelector(selector);
      if (!scope) throw new Error(`missing action row ${selector}`);
      const controls = [...scope.querySelectorAll<HTMLElement>(".cv-iconbtn")].filter(visible).map((button) => {
        const svg = button.querySelector<SVGSVGElement>(":scope > svg")!;
        const b = button.getBoundingClientRect();
        const g = svg.getBoundingClientRect();
        const i = ink(svg);
        return {
          left: b.left,
          width: b.width,
          cx: b.left + b.width / 2,
          cy: b.top + b.height / 2,
          glyphCx: g.left + g.width / 2,
          glyphCy: g.top + g.height / 2,
          glyphW: g.width,
          glyphH: g.height,
          inkCx: i.cx,
          inkCy: i.cy,
          chevron: button.classList.contains("cv-turn-retry-menu"),
          paths: [...svg.querySelectorAll("path")].map((p) => p.getAttribute("d") ?? ""),
        };
      });
      let timeGap: number | null = null;
      if (time) {
        const el = document.querySelector(time)!;
        const text = el.firstChild!;
        const range = document.createRange();
        range.setStart(text, text.textContent!.trimEnd().length - 1);
        range.setEnd(text, text.textContent!.trimEnd().length);
        const firstGlyph = scope.querySelector(".cv-iconbtn > svg")!.getBoundingClientRect();
        timeGap = firstGlyph.left - range.getBoundingClientRect().right;
      }
      return { kind, controls, timeGap };
    });
  });
}

function check(rows: Row[], state: string) {
  expect(rows.map((row) => row.kind)).toEqual(["prompt", "received", "turn"]);
  for (const row of rows) {
    const where = `${row.kind} (${state})`;
    const chevron = row.controls.findIndex((c) => c.chevron);
    expect(chevron, `${where}: Retry's model chevron`).toBeGreaterThan(0);
    const retry = row.controls[chevron - 1]!;
    expect(retry.paths, `${where}: Retry is the pack's action.reload`).toEqual(reload);
    const pitch = row.controls[0]!.width;
    for (const [index, control] of row.controls.entries()) {
      const at = `${where} control ${index + 1}${control.chevron ? " (chevron)" : ""}`;
      expect(Math.abs(control.width - pitch), `${at}: one slot width`).toBeLessThanOrEqual(TOLERANCE);
      if (index > 0)
        expect(Math.abs(control.cx - row.controls[index - 1]!.cx - pitch), `${at}: slots abut`).toBeLessThanOrEqual(
          TOLERANCE,
        );
      expect(control.glyphW, `${at}: 16 glyph box`).toBe(16);
      expect(control.glyphH, `${at}: 16 glyph box`).toBe(16);
      expect(Math.abs(control.glyphCx - control.cx), `${at}: glyph box centred`).toBeLessThanOrEqual(TOLERANCE);
      expect(Math.abs(control.glyphCy - control.cy), `${at}: glyph box on mid`).toBeLessThanOrEqual(TOLERANCE);
      expect(Math.abs(control.inkCy - row.controls[0]!.cy), `${at}: ink on the row's mid`).toBeLessThanOrEqual(
        TOLERANCE,
      );
    }
    const chev = row.controls[chevron]!;
    expect(Math.abs(chev.inkCy - chev.glyphCy), `${where}: chevron ink centred (y)`).toBeLessThanOrEqual(0.05);
    expect(Math.abs(chev.inkCx - chev.glyphCx), `${where}: chevron ink centred (x)`).toBeLessThanOrEqual(0.05);
    if (row.timeGap !== null)
      expect(Math.abs(row.timeGap - 8), `${where}: age ends 8 before the first glyph box`).toBeLessThanOrEqual(
        TOLERANCE,
      );
  }
}

await requireBrowserLane("message-action-row-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-glyph-alignment.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const theme of ["dark", "light"] as const)
    test(`${theme}: action rows are one pitch, one mid and one glyph set, idle and hovered`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
      try {
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}`);
        await page.locator('[data-action-row="turn"] .cv-turn-retry-menu').waitFor();
        await page.evaluate(() => document.fonts.ready);
        const idle = await measure(page);
        console.log(`ACTION_ROW_METRICS ${JSON.stringify({ theme, state: "idle", rows: idle })}`);
        if (process.env.CMUX_ACTION_ROW_CAPTURES === "1")
          console.log(
            `ACTION_ROW_CAPTURE ${JSON.stringify({ name: `${theme}-idle.png`, base64: (await page.screenshot()).toString("base64") })}`,
          );
        expect(errors).toEqual([]);
        check(idle, "idle");
        // Hover the received row's chevron, then open its menu: the row keeps its geometry.
        await page.hover('[data-received-row="retryable"] .cv-turn-retry-menu');
        const hovered = await measure(page);
        check(hovered, "hover");
        expect(hovered).toEqual(idle);
        await page.click('[data-received-row="retryable"] .cv-turn-retry-menu');
        await page.locator('[role="menu"]').first().waitFor();
        const open = await measure(page);
        check(open, "menu open");
        expect(open).toEqual(idle);
      } finally {
        await page.close();
      }
    });
});
