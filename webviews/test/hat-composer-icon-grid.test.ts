// l10n-allow-file: types a probe draft into the gallery's composer; no shipped copy.
// The composer hat on the composer's own columns, and the prompt's words on its controls' centre line,
// at every density (cmux#51039; the person, 2026-11-22: "its not perfectly the same icon size (we need
// to make sure that we do this well for all densities) and make sure that the spacing left and right is
// all equal", "can we make sure that the text in the input box is vertically centered perfectly", and
// "maybe we should align the + and the terminal icon here?"). Measured in the gallery's real pane:
//   - the hat's leading mark, its lines' and its plan steps' marks centre on +; their words start
//     where the prompt's do;
//   - the panel button and the chevron centre on Stop and the mic, in the composer's control box, and
//     every glyph of the header row draws the composer's glyph size, its ink the composer's;
//   - the placeholder's and a typed draft's capitals centre on +, Stop and the mic, and stay there
//     after a draft grows to several lines and back.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { pageDensities } from "../src/gallery/pageDensityFixtures";

await requireBrowserLane("hat-composer-icon-grid.test.ts", async () => {
  setDefaultTimeout(300_000);
  const KINDS = { entry: "agent-pane.feel-plan-tray", variant: "one" } as const;
  const PLAN = { entry: "agent-pane.plan-hat-working", variant: "between" } as const;
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
    await warmGalleryFrame(server, KINDS.entry, { browser, params: { variant: KINDS.variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async ({ entry, variant }: { entry: string; variant: string }, scale: number): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({
      viewport: { width: 900, height: 720 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: "normal" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(".acpmux-running-tray[data-open] .acpmux-running-tray__plan");
    await page.evaluate((value) => {
      const root = document.documentElement;
      for (const name of ["--cmux-density-scale", "--cmux-density-text-scale", "--cmux-row-icon-scale"])
        root.style.setProperty(name, String(value));
      window.dispatchEvent(new Event("cmux-ui-scale-change"));
    }, scale);
    await page.evaluate(() =>
      document.fonts.ready.then(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)))),
    );
    // The hat's header holds its words a moment (ComposerHatHead) and redraws at the new density after;
    // measure once its leading mark has held still for 20 painted frames.
    await page.evaluate(async () => {
      const lead = () =>
        document
          .querySelector(".acpmux-running-tray__head :is(.acpmux-lineage__icon, .acpmux-running-tray__kind) svg")
          ?.getBoundingClientRect();
      let last = "";
      let still = 0;
      for (let index = 0; index < 240 && still < 20; index += 1) {
        await window.cmuxPaintFrame();
        const rect = lead();
        const now = rect ? `${rect.left},${rect.top},${rect.width}` : "";
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });
    return page;
  };

  /// Every measure the contract reads, in CSS px.
  const measure = (page: Page) =>
    page.evaluate(() => {
      const q = <T extends Element = Element>(selector: string, from: ParentNode = document) =>
        from.querySelector<T>(selector);
      const box = (node: Element | null | undefined) => {
        if (!node) return null;
        const r = node.getBoundingClientRect();
        // The glyph's ink: its shapes' union.
        const shapes = [...node.querySelectorAll("path,rect,circle,line,polyline,polygon,ellipse")]
          .map((shape) => shape.getBoundingClientRect())
          .filter((shape) => shape.width + shape.height > 0);
        const ink = shapes.length
          ? Math.max(
              Math.max(...shapes.map((s) => s.right)) - Math.min(...shapes.map((s) => s.left)),
              Math.max(...shapes.map((s) => s.bottom)) - Math.min(...shapes.map((s) => s.top)),
            )
          : 0;
        // Its laid-out size, before a transform (the open chevron turns): the box's own, not its bounds.
        const style = getComputedStyle(node);
        const w = Number.parseFloat(style.width) || r.width;
        const h = Number.parseFloat(style.height) || r.height;
        return { w, h, cx: r.left + r.width / 2, cy: r.top + r.height / 2, ink };
      };
      const firstText = (node: Element | null | undefined) => {
        if (!node) return null;
        const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
        let text: Node | null;
        while ((text = walker.nextNode())) if ((text.textContent ?? "").trim()) break;
        if (!text) return null;
        const range = document.createRange();
        range.setStart(text, 0);
        range.setEnd(text, 1);
        return range.getBoundingClientRect();
      };
      const textLeft = (node: Element | null | undefined) => firstText(node)?.left ?? null;
      const composer = q(".acpmux-composer-box")!;
      const head = q(".acpmux-running-tray__head")!;
      const plus = q(".acpmux-composer-plus button") ?? q(".acpmux-composer-plus svg")!.closest("button")!;
      // The box's trailing controls: the mic last, Stop before it while a turn runs.
      const right = [...composer.querySelectorAll("button")].filter(
        (b) =>
          b.getBoundingClientRect().left >
          composer.getBoundingClientRect().left + composer.getBoundingClientRect().width / 2,
      );
      const mic = right.at(-1)!;
      const stop = right.length > 1 ? right.at(-2)! : null;
      const placeholder = q(".acpmux-composer-box .acpmux-md-placeholder");
      // The placeholder's baseline, from a zero box on it, and its font's capital height.
      let capMiddle: number | null = null;
      const lead = firstText(placeholder);
      if (placeholder && lead) {
        const mark = document.createElement("span");
        mark.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline";
        placeholder.prepend(mark);
        const baseline = mark.getBoundingClientRect().top;
        mark.remove();
        const style = getComputedStyle(placeholder);
        const context = document.createElement("canvas").getContext("2d")!;
        context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
        capMiddle = baseline - context.measureText("H").actualBoundingBoxAscent / 2;
      }
      const line = q(".acpmux-running-tray .acpmux-agent-line__button");
      const step = q(".acpmux-running-tray__plan .cv-plan__item");
      return {
        plus: box(plus)!,
        plusGlyph: box(plus.querySelector("svg"))!,
        stop: box(stop),
        mic: box(mic)!,
        micGlyph: box(mic.querySelector("svg"))!,
        actionGap: stop ? mic.getBoundingClientRect().left - stop.getBoundingClientRect().right : null,
        headLead: box(q(":scope > .acpmux-lineage__icon > svg, .acpmux-running-tray__kind:first-child > svg", head)),
        headText: textLeft(q(".acpmux-running-tray__kind-text, :scope > .acpmux-running-tray__title", head)),
        head: box(head)!,
        panel: box(q(".acpmux-running-tray__open"))!,
        panelGlyph: box(q(".acpmux-running-tray__open > svg"))!,
        chevronGlyph: box(q(".acpmux-running-tray__chevron svg"))!,
        lineIcon: box(q(":scope > .acpmux-lineage__icon", line ?? document.createElement("i"))),
        lineText: textLeft(q(":scope > .acpmux-summary-text", line ?? document.createElement("i"))),
        stepMark: box(q(".cv-plan__mark", step ?? document.createElement("i"))),
        stepText: textLeft(q(".cv-plan__title", step ?? document.createElement("i"))),
        stepLine: (() => {
          const r = firstText(q(".cv-plan__title", step ?? document.createElement("i")));
          return r ? r.top + r.height / 2 : null;
        })(),
        promptText: textLeft(placeholder),
        placeholderTop: lead?.top ?? null,
        capMiddle,
        boxTop: composer.getBoundingClientRect().top,
        boxHeight: composer.getBoundingClientRect().height,
      };
    });

  /// The composer's action gap per density, read where Stop shows (KINDS runs first).
  const KINDS_GAP = new Map<string, number>();
  for (const density of pageDensities) {
    for (const fixture of [KINDS, PLAN]) {
      test(`${density.name}: ${fixture.entry} ${fixture.variant} stands on the composer's columns`, async () => {
        const page = await open(fixture, density.scale);
        try {
          const m = await measure(page);
          const off: string[] = [];
          const near = (what: string, a: number | null | undefined, b: number | null | undefined, slack = 0.5) => {
            if (a == null || b == null || !Number.isFinite(a) || !Number.isFinite(b) || Math.abs(a - b) > slack)
              off.push(`${what}: ${a} vs ${b}`);
          };
          // The left column: every leading mark on +'s centre, every row's words at the prompt's start.
          near("header mark on +", m.headLead?.cx, m.plus.cx);
          near("step mark on +", m.stepMark?.cx, m.plus.cx);
          if (fixture === KINDS) near("line mark on +", m.lineIcon?.cx, m.plus.cx);
          near("header words at the prompt's", m.headText, m.promptText);
          near("step words at the prompt's", m.stepText, m.promptText);
          if (fixture === KINDS) near("line words at the prompt's", m.lineText, m.promptText);
          // The right columns: the panel button is the control box in Stop's column (one action gap
          // before the mic when no turn runs), the chevron on the mic.
          const stopColumn = m.stop?.cx ?? m.mic.cx - m.mic.w - KINDS_GAP.get(density.name)!;
          near("panel button over Stop", m.panel.cx, stopColumn);
          near("panel button width", m.panel.w, m.mic.w);
          near("panel button height", m.panel.h, m.mic.h);
          near("chevron over the mic", m.chevronGlyph.cx, m.mic.cx);
          // One glyph size: the header's glyphs grow with the composer's glyph (the mic's; + is drawn a step
          // over the other icons) and draw its ink.
          const glyph = m.micGlyph.w * (14 / 16);
          near("panel glyph size", m.panelGlyph.w, glyph);
          near("chevron glyph size", m.chevronGlyph.w, glyph);
          near("header mark size", m.headLead?.w, glyph);
          near("panel ink vs the mic's", m.panelGlyph.ink, m.micGlyph.ink, density.scale);
          if (fixture === KINDS) near("header mark ink vs the mic's", m.headLead?.ink, m.micGlyph.ink, density.scale);
          // The steps' marks are the header glyph's ink size (12 of its 14 px) at every density, each on
          // its step's first line (the person, 2026-11-24: the card's and the plan's icons the same size).
          near("step mark size", m.stepMark?.w, glyph * (12 / 14), 0.25);
          near("step mark on its first line", m.stepMark?.cy, m.stepLine, 0.75);
          // The header's marks on one centre line.
          near("header mark centre line", m.headLead?.cy, m.head.cy);
          near("panel centre line", m.panel.cy, m.head.cy);
          near("chevron centre line", m.chevronGlyph.cy, m.head.cy);
          if (fixture === KINDS && m.actionGap != null) KINDS_GAP.set(density.name, m.actionGap);
          expect(off).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }

    test(`${density.name}: the prompt's words centre on the composer's controls, one line or after several`, async () => {
      const page = await open(KINDS, density.scale);
      try {
        const empty = await measure(page);
        const off: string[] = [];
        const near = (what: string, a: number | null | undefined, b: number | null | undefined, slack: number) => {
          if (a == null || b == null || Math.abs(a - b) > slack) off.push(`${what}: ${a} vs ${b}`);
        };
        // The capitals' middle on +, Stop and the mic.
        near("placeholder capitals on +", empty.capMiddle, empty.plus.cy, 0.25);
        near("Stop on +", empty.stop?.cy, empty.plus.cy, 0.25);
        near("mic on +", empty.mic.cy, empty.plus.cy, 0.25);
        // A typed draft sits where the placeholder did, and its caret centres on the controls.
        await page.click(".acpmux-composer-box [contenteditable]");
        await page.keyboard.type("Held the line");
        const typed = await page.evaluate(() => {
          const editor = document.querySelector(".acpmux-composer-box [contenteditable]")!;
          const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
          const text = walker.nextNode()!;
          const range = document.createRange();
          range.setStart(text, 0);
          range.setEnd(text, 1);
          const caret = getSelection()!.getRangeAt(0).getBoundingClientRect();
          return { top: range.getBoundingClientRect().top, caretMiddle: caret.top + caret.height / 2 };
        });
        near("typed words where the placeholder's were", typed.top, empty.placeholderTop, 0.25);
        near("caret on +", typed.caretMiddle, empty.plus.cy, 0.75);
        // Grown to three lines and back to one, the line is where it was, on the controls' centre.
        for (let i = 0; i < 2; i += 1) await page.keyboard.press("Shift+Enter");
        await page.keyboard.type("x");
        await page.keyboard.press("ControlOrMeta+a");
        await page.keyboard.press("Backspace");
        await page.waitForSelector(".acpmux-composer-box .acpmux-md-placeholder");
        // The field eases back to one line; read it once its height holds.
        await page.waitForFunction(
          (height) =>
            Math.abs(document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height - height) < 0.25,
          empty.boxHeight,
        );
        await page.evaluate(() => window.cmuxPaintFrame());
        const after = await measure(page);
        near("placeholder capitals on + after growing", after.capMiddle, after.plus.cy, 0.25);
        near("+ back where it was in the box", after.plus.cy - after.boxTop, empty.plus.cy - empty.boxTop, 0.25);
        near("the box back to one line", after.boxHeight, empty.boxHeight, 0.25);
        expect(off).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }

  // The Goal row over the plan's hat (the person, 2026-11-23: "icons are not matching properly"): its
  // dot, the plan's mark and + share one leading column, the words one start, and the chevrons and the
  // panel button one trailing edge and one glyph size, each on its first line's centre.
  for (const density of pageDensities)
    for (const scheme of ["dark", "light"] as const)
      test(`${density.name}, ${scheme}: the Goal row stands on the hat's columns`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width: 900, height: 720 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
          colorScheme: scheme,
        });
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-goal", { variant: "with-plan", width: "normal" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForSelector(".acpmux-goal[data-look] .acpmux-goal-mark");
          await page.waitForSelector(".acpmux-running-tray__head");
          await page.evaluate((value) => {
            const root = document.documentElement;
            for (const name of ["--cmux-density-scale", "--cmux-density-text-scale", "--cmux-row-icon-scale"])
              root.style.setProperty(name, String(value));
            window.dispatchEvent(new Event("cmux-ui-scale-change"));
          }, density.scale);
          await page.evaluate(() =>
            document.fonts.ready.then(
              () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
            ),
          );
          const m = await page.evaluate(() => {
            const q = (selector: string) => document.querySelector(selector);
            const rect = (node: Element | null) => {
              if (!node) return null;
              const r = node.getBoundingClientRect();
              const style = getComputedStyle(node);
              return {
                cx: r.left + r.width / 2,
                cy: r.top + r.height / 2,
                right: r.right,
                w: Number.parseFloat(style.width) || r.width,
              };
            };
            const textLeft = (node: Element | null) => {
              if (!node) return null;
              const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
              let text: Node | null;
              while ((text = walker.nextNode())) if ((text.textContent ?? "").trim()) break;
              if (!text) return null;
              const range = document.createRange();
              range.setStart(text, 0);
              range.setEnd(text, 1);
              const r = range.getBoundingClientRect();
              // The text box's start (each font's first letter has its own side bearing) and its line's centre.
              return { left: node.getBoundingClientRect().left, cy: r.top + r.height / 2 };
            };
            const head = q(".acpmux-running-tray__head")!;
            return {
              plus: rect(q(".acpmux-composer-plus svg")),
              goalMark: rect(q(".acpmux-goal[data-look] .acpmux-goal-mark > span")),
              goalText: textLeft(q(".acpmux-goal[data-look] .acpmux-goal-state")),
              goalChevron: rect(q(".acpmux-goal[data-look] .acpmux-goal-chevron > svg")),
              goalChevronBox: rect(q(".acpmux-goal[data-look] .acpmux-goal-chevron")),
              hatMark: rect(
                head.querySelector(
                  ":scope > .acpmux-lineage__icon > svg, .acpmux-running-tray__kind:first-child > svg",
                ),
              ),
              hatText: textLeft(
                head.querySelector(".acpmux-running-tray__kind-text, :scope > .acpmux-running-tray__title"),
              ),
              hatChevron: rect(q(".acpmux-running-tray__chevron svg")),
              hatChevronBox: rect(q(".acpmux-running-tray__chevron")),
              panel: rect(q(".acpmux-running-tray__open > svg")),
              // The two carets' drawing: one component (its class), one stroke, one ink.
              carets: [".acpmux-goal[data-look] .acpmux-goal-chevron > svg", ".acpmux-running-tray__chevron svg"].map(
                (selector) => {
                  const svg = q(selector);
                  if (!svg) return null;
                  const shapes = [...svg.querySelectorAll("path,polyline,line")].map((shape) =>
                    shape.getBoundingClientRect(),
                  );
                  return {
                    shared: svg.classList.contains("acpmux-hat-chevron"),
                    stroke: getComputedStyle(svg.querySelector("path,polyline,line") ?? svg).strokeWidth,
                    ink: shapes.length ? Math.max(...shapes.map((r) => r.width)) : 0,
                  };
                },
              ),
            };
          });
          const off: string[] = [];
          const near = (what: string, a: number | null | undefined, b: number | null | undefined, slack = 0.5) => {
            if (a == null || b == null || !Number.isFinite(a) || !Number.isFinite(b) || Math.abs(a - b) > slack)
              off.push(`${what}: ${a} vs ${b}`);
          };
          near("goal dot on the plan's mark", m.goalMark?.cx, m.hatMark?.cx);
          // The Goal mark is the plan's mark size: 12 of the header glyph's 14 px (2026-11-24).
          near("goal mark size", m.goalMark?.w, (m.hatMark?.w ?? 0) * (12 / 14), 0.25);
          near("goal dot on +", m.goalMark?.cx, m.plus?.cx);
          near("goal words at the plan's", m.goalText?.left, m.hatText?.left);
          near("goal chevron over the plan's", m.goalChevron?.cx, m.hatChevron?.cx);
          near("goal chevron's right edge", m.goalChevron?.right, m.hatChevron?.right);
          near("goal chevron size", m.goalChevron?.w, m.hatChevron?.w);
          near("panel glyph size", m.panel?.w, m.hatChevron?.w);
          const [goalCaret, hatCaret] = m.carets;
          if (!goalCaret?.shared || !hatCaret?.shared) off.push("both carets draw HatChevron");
          if (goalCaret?.stroke !== hatCaret?.stroke)
            off.push(`caret stroke: ${goalCaret?.stroke} vs ${hatCaret?.stroke}`);
          near("caret ink", goalCaret?.ink, hatCaret?.ink, 0.25);
          near("goal dot on its first line", m.goalMark?.cy, m.goalText?.cy, 1);
          near("goal chevron on its first line", m.goalChevron?.cy, m.goalText?.cy, 1);
          expect(off).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
