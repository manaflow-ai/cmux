// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// One column, one gap, nothing removed (Leo, 2026-10-30: "the stupid right indent misalignemnt").
// Every part over the composer (a question, a notice, the pull requests, the recap, the running
// tray and its header, the agents pill, the queue) shares the composer box's left and right edges at
// every width (the narrow outset under 298px of column and --cv-inset-end included) and the box's
// radius token. The stack owns the spacing: one token (--acpmux-stack-gap) between parts, no part
// with an outer margin or bottom padding of its own, and the last part right on the box. In a row of
// a part, the last trailing mark centres 22px from the part's right edge and a mark before it 42px
// (the 22/42 grid, design/grid.md 5.5); an empty slot never pushes the last mark in.
//
// Real gallery frames at 1100, 420 and 280px. A part this PR has fixed fails the test on a miss
// (FIXED); every other part reports its misses as warnings (design/grid.md §7: a surface starts at
// warning level and turns into a failure when it is fixed). With FAST_CHECKS_OUT (cmux-ci) or
// CMUX_STACK_EDGES_CAPTURE set, the measurements are written as stack-edges.json there, with 2x light
// and dark stills at 1100 and 280 and a close-up of the tray's right end.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Part = {
  name: string;
  left: number;
  right: number;
  top: number;
  bottom: number;
  painted: boolean;
  radii: number[];
  gap: number | null;
  last: boolean;
  /** Each row's trailing marks (their centres' distance from the part's right edge), right first. */
  trails: { row: string; marks: number[] }[];
  /** Each row's leading mark: its centre's distance from the part's left edge (for the record). */
  leads: number[];
};
type Frame = {
  box: { left: number; right: number; top: number; radius: number };
  token: number | null;
  parts: Part[];
};

await requireBrowserLane("agent-pane-stack-edges.test.ts", async () => {
  setDefaultTimeout(840_000);
  const out = process.env.CMUX_STACK_EDGES_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const WIDTHS = [1100, 420, 280];
  /** The parts this change put on the rule: a miss fails. The rest are warnings. */
  const FIXED = new Set([
    "acpmux-running-tray",
    "acpmux-pr-stack",
    "acpmux-pr-count-host",
    "acpmux-recap",
    "acpmux-agents-pill-anchor",
    "acpmux-host-line",
  ]);
  const FRAMES: { entry: string; variant: string }[] = [
    { entry: "agent-pane.subagent-tray", variant: "between-turns" },
    { entry: "agent-pane.subagent-tray", variant: "several-running" },
    { entry: "agent-pane.subagent-tray", variant: "duration-columns" },
    { entry: "agent-pane.subagent-tray", variant: "panel-two" },
    { entry: "agent-pane.subagent-tray", variant: "short-dock" },
    { entry: "agent-pane.bottom-stack", variant: "pr-queue" },
    { entry: "agent-pane.bottom-stack", variant: "trusted-permission-queue" },
    { entry: "agent-pane.bottom-stack", variant: "compact-trust-queue" },
    { entry: "agent-pane.bottom-stack", variant: "short-400-long-draft" },
    { entry: "agent-pane.pr-dock", variant: "inline-pills" },
    { entry: "agent-pane.pr-dock", variant: "full-bars" },
    { entry: "agent-pane.recap-card", variant: "recap-card" },
    { entry: "agent-pane.bottom-stack-styles", variant: "collapsed" },
    { entry: "agent-pane.bottom-stack-styles", variant: "expanded" },
    { entry: "agent-pane.bottom-stack-styles", variant: "prs-open" },
  ];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const record: Record<string, Frame | string> = {};

  beforeAll(async () => {
    if (out) mkdirSync(path.join(out, "stills"), { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [...new Set(FRAMES.map((frame) => frame.entry))], { browser });
  });
  afterAll(async () => {
    if (out) writeFileSync(path.join(out, "stack-edges.json"), JSON.stringify(record, null, 2));
    await browser?.close();
    await vite?.close();
  });

  async function open(entry: string, variant: string, width: number, theme?: string, scale = 1): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 680 }, deviceScaleFactor: scale });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme })}`);
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    // Let motion that ends (an entrance, a fold) end, so a part is measured where it rests; a running
    // line's spinner turns for as long as it runs and is not waited for.
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll(".acpmux-dock, .acpmux-dock *")].every((node) =>
          node
            .getAnimations()
            .every(
              (animation) =>
                animation.playState !== "running" ||
                !Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)),
            ),
        ),
      undefined,
      { timeout: 10_000 },
    );
    return page;
  }

  /** Runs in the page: the box, the stack token and every part's measures. */
  function measure(): Frame | null {
    const dock = document.querySelector(".acpmux-dock");
    const boxNode = document.querySelector(".acpmux-composer-box");
    if (!dock || !boxNode) return null;
    const box = boxNode.getBoundingClientRect();
    const radius = parseFloat(getComputedStyle(boxNode).borderBottomLeftRadius) || 0;
    let token: number | null = null;
    if (getComputedStyle(dock).getPropertyValue("--acpmux-stack-gap").trim()) {
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--acpmux-stack-gap)";
      dock.append(probe);
      token = probe.getBoundingClientRect().height;
      probe.remove();
    }
    const shown = (el: Element) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      return r.width > 0.5 && r.height > 0.5 && s.visibility !== "hidden" && s.display !== "none";
    };
    const visible = (el: Element) => {
      if (!shown(el)) return false;
      for (let node: Element | null = el; node; node = node.parentElement)
        if (parseFloat(getComputedStyle(node).opacity) === 0) return false;
      return true;
    };
    const paints = (el: Element) => {
      const s = getComputedStyle(el);
      const fill = s.backgroundColor !== "rgba(0, 0, 0, 0)" && s.backgroundColor !== "transparent";
      return fill || s.boxShadow !== "none" || parseFloat(s.borderTopWidth) > 0 || parseFloat(s.borderLeftWidth) > 0;
    };
    const composer = dock.querySelector(":scope > .acpmux-composer");
    const nodes = [...dock.children].filter((el) => el !== composer && shown(el));
    const queue = composer?.querySelector(":scope > .acpmux-composer-queue");
    if (queue && shown(queue)) nodes.push(queue);
    const ROWS =
      ".acpmux-running-tray__head, .acpmux-agent-line, .acpmux-running-tray__finished, .acpmux-pr-stack__chip, .acpmux-composer-queue > li";
    const parts: Part[] = nodes.map((el, index) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      // The part's painted surface: itself, or a descendant across its content width (a card in a
      // band); with none, its content box.
      const content = { left: r.left + parseFloat(s.paddingLeft), right: r.right - parseFloat(s.paddingRight) };
      let surface: Element | null = paints(el) ? el : null;
      if (!surface)
        surface =
          [...el.querySelectorAll("*")].find(
            (node) =>
              shown(node) && paints(node) && node.getBoundingClientRect().width >= 0.9 * (content.right - content.left),
          ) ?? null;
      const edge = surface ? surface.getBoundingClientRect() : { ...content, top: r.top, bottom: r.bottom };
      const cs = surface ? getComputedStyle(surface) : undefined;
      const radii = cs
        ? [cs.borderTopLeftRadius, cs.borderTopRightRadius, cs.borderBottomRightRadius, cs.borderBottomLeftRadius].map(
            (value) => parseFloat(value) || 0,
          )
        : [];
      // The gap under the part: to the next part, or for the last one to the composer's first part.
      const next = nodes[index + 1];
      let below: number | null = null;
      if (next) below = next.getBoundingClientRect().top;
      else if (el === queue) below = box.top;
      else if (composer) {
        const first = [...composer.children].find((child) => shown(child) && child !== queue) ?? boxNode;
        below = (queue && shown(queue) ? queue : first).getBoundingClientRect().top;
      }
      const rows = el.matches(ROWS) ? [el] : [...el.querySelectorAll(ROWS)].filter(shown);
      const trails = rows.map((row) => {
        const rr = row.getBoundingClientRect();
        const marks = [...row.querySelectorAll("svg")]
          .filter(visible)
          .map((svg) => {
            const g = svg.getBoundingClientRect();
            return (g.left + g.right) / 2;
          })
          .filter((centre) => centre > (rr.left + rr.right) / 2)
          .map((centre) => Math.round((edge.right - centre) * 10) / 10)
          .sort((a, b) => a - b);
        return { row: row.className.split(" ").find((name) => name.startsWith("acpmux-")) ?? row.tagName, marks };
      });
      const leads = rows.flatMap((row) => {
        const rr = row.getBoundingClientRect();
        const first = [...row.querySelectorAll("svg")].filter(visible).find((svg) => {
          const g = svg.getBoundingClientRect();
          return (g.left + g.right) / 2 < (rr.left + rr.right) / 2;
        });
        if (!first) return [];
        const g = first.getBoundingClientRect();
        return [Math.round(((g.left + g.right) / 2 - edge.left) * 10) / 10];
      });
      return {
        name: [...el.classList].find((name) => name.startsWith("acpmux-")) ?? el.tagName.toLowerCase(),
        left: edge.left,
        right: edge.right,
        top: r.top,
        bottom: r.bottom,
        painted: !!surface,
        radii,
        gap: below === null ? null : Math.round((below - r.bottom) * 10) / 10,
        last: !next,
        trails,
        leads,
      };
    });
    return { box: { left: box.left, right: box.right, top: box.top, radius }, token, parts };
  }

  function misses(label: string, frame: Frame): { fixed: boolean; text: string }[] {
    const found: { fixed: boolean; text: string }[] = [];
    for (const part of frame.parts) {
      const fixed = FIXED.has(part.name);
      const miss = (text: string) => found.push({ fixed, text: `${label} ${part.name}: ${text}` });
      const left = part.left - frame.box.left;
      const right = part.right - frame.box.right;
      if (Math.abs(left) > 0.5 || Math.abs(right) > 0.5)
        miss(`edges ${left.toFixed(1)} / ${right.toFixed(1)}px off the box's`);
      if (part.painted && part.radii.some((radius) => radius > 0.5 && Math.abs(radius - frame.box.radius) > 0.5))
        miss(`radius ${part.radii.join("/")}, the box's is ${frame.box.radius}`);
      if (frame.token === null) miss("the stack has no --acpmux-stack-gap");
      else if (part.gap !== null) {
        const want = part.last || part.name === "acpmux-composer-queue" ? 0 : frame.token;
        if (Math.abs(part.gap - want) > 0.5) miss(`${part.gap}px under it, not ${want}`);
      }
      for (const { row, marks } of part.trails) {
        if (marks.length === 0) continue;
        if (Math.abs(marks[0]! - 22) > 0.5) miss(`${row}'s last trailing mark ${marks[0]}px from the right, not 22`);
        for (const mark of marks.slice(1))
          if (Math.abs(mark - 42) > 0.5) miss(`${row}'s trailing mark ${mark}px from the right, not on 42`);
      }
    }
    return found;
  }

  test("every part over the composer shares the box's edges and radius, one stack gap, and trails on 22/42", async () => {
    const failures: string[] = [];
    const warnings: string[] = [];
    for (const width of WIDTHS)
      for (const { entry, variant } of FRAMES) {
        const label = `${entry}:${variant} @${width}`;
        let page: Page | undefined;
        try {
          page = await open(entry, variant, width);
          const frame = await page.evaluate(measure);
          if (!frame) {
            record[label] = "no dock or box";
            warnings.push(`${label}: no dock or box`);
            continue;
          }
          record[label] = frame;
          for (const { fixed, text } of misses(label, frame)) (fixed ? failures : warnings).push(text);
        } catch (error) {
          failures.push(`${label}: did not load (${String(error).split("\n")[0]})`);
        } finally {
          await page?.close();
        }
      }
    for (const warning of warnings) console.log(`::warning::stack-edges ${warning}`);
    console.log(`stack-edges: ${failures.length} failures, ${warnings.length} warnings`);
    expect(failures).toEqual([]);
  });

  test("stills", async () => {
    if (!out) return;
    const STILLS: [string, string, string][] = [
      ["agent-pane.bottom-stack-styles", "collapsed", "tray-collapsed"],
      ["agent-pane.bottom-stack-styles", "expanded", "tray-expanded"],
      ["agent-pane.bottom-stack-styles", "prs-open", "pr-control"],
      ["agent-pane.recap-card", "recap-card", "recap"],
    ];
    for (const width of [1100, 280])
      for (const [theme, scheme] of [
        ["Apple System Colors", "dark"],
        ["Apple System Colors Light", "light"],
      ] as const) {
        for (const [entry, variant, name] of STILLS) {
          const page = await open(entry, variant, width, theme, 2);
          if (variant === "prs-open") await page.locator(".acpmux-pr-stack__link").first().hover();
          await page.screenshot({ path: path.join(out, "stills", `${name}-${width}-${scheme}.png`) });
          // The right end of the tray and the box under it, where the chevrons and Stop line up.
          if (variant === "expanded") {
            const tray = (await page.locator(".acpmux-dock > .acpmux-running-tray").boundingBox())!;
            const box = (await page.locator(".acpmux-composer-box").boundingBox())!;
            const w = Math.min(200, tray.width);
            await page.screenshot({
              path: path.join(out, "stills", `chevrons-${width}-${scheme}.png`),
              clip: { x: tray.x + tray.width - w, y: tray.y, width: w, height: box.y + box.height - tray.y },
            });
          }
          await page.close();
        }
      }
  });
});
