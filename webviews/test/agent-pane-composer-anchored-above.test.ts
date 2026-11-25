// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and the stand-in banner's text, not shipped UI.
//
// Leo, 2026-11-24, of the rolling summary line at the top of the open chat: "oddly this thing's
// shifting affects the composer at the bottom to varying degrees. but that shouldn't happen. we need to
// have more things decoupled from posisble shifts. this is a pattern we need to take care of."
//
// Nothing above the composer moves it. The composer form (`.acpmux-composer`) and its card
// (`.acpmux-composer-box`) hold their top, bottom and height on every painted frame while the things
// above them change size: the header grows and shrinks (by 0, 28 and 60 px, through its own box and
// through `--acpmux-header-height`) and enters and leaves the tab row; a banner comes and goes at the
// stage's top; a line in the header (the rolling summary's place, in its own row and in the tab row)
// grows past the pane's width and goes; the connecting and unavailable states come and go over the
// transcript; a row in view grows after it mounted and shrinks back; the pane changes only its width.
// A real cold open whose attach acpmux holds (an empty stage, then the chat) is read the same way. Real Chromium and WebKit
// against the pane's dev entry and a stand-in acpmux (support/papercutChat.ts). One JSON line per case
// (`composer-anchored:`) is the PR's before/after number. Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-composer-anchored-above.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-composer-anchored-above.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  const only = process.env.COMPOSER_ANCHORED_ENGINES?.split(",");
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`agent-pane-composer-anchored-above: skipping ${engine[0]}: ${String(error).slice(0, 400)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("nothing above the composer moves it", () => test("no engine", () => {}));
    return;
  }

  const TURNS = 30;
  const browsers = new Map<string, Browser>();
  let engine = engines[0]![0];
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
    pane = await papercutPane(() => browsers.get(engine)!, {
      turns: TURNS,
      running: false,
    });
  });
  afterAll(async () => {
    await pane?.close();
    for (const browser of browsers.values()) await browser.close();
  });

  type Box = { top: number; bottom: number; height: number };
  type Frame = { composer?: Box; box?: Box };

  /// Starts reading, after every painted frame, the composer form's and its card's boxes into
  /// `window.__anchored`; the returned page function stops it.
  const startRecording = (page: Page) =>
    page.evaluate(() => {
      const frames: { composer?: Box; box?: Box }[] = [];
      type Box = { top: number; bottom: number; height: number };
      const read = (selector: string): Box | undefined => {
        const element = document.querySelector(selector);
        if (!element) return undefined;
        const rect = element.getBoundingClientRect();
        if (rect.height <= 0) return undefined;
        const round = (value: number) => Math.round(value * 10) / 10;
        return {
          top: round(rect.top),
          bottom: round(rect.bottom),
          height: round(rect.height),
        };
      };
      const globals = window as unknown as {
        __anchored: typeof frames;
        __anchoredStop: () => void;
      };
      globals.__anchored = frames;
      globals.__anchoredStop = window.cmuxAfterPaint(() => {
        frames.push({
          composer: read("form.acpmux-composer"),
          box: read(".acpmux-composer-box"),
        });
      });
    });
  const stopRecording = (page: Page) =>
    page.evaluate(() => {
      const globals = window as unknown as {
        __anchored: Frame[];
        __anchoredStop: () => void;
      };
      globals.__anchoredStop();
      return globals.__anchored;
    });
  const paint = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let i = 0; i < count; i++) await window.cmuxPaintFrame();
    }, count);

  const PARTS = ["composer", "box"] as const;
  const EDGES = ["top", "bottom", "height"] as const;
  /// Each part's edges' largest move from the first recorded frame, and the frames where any moved.
  const report = (scenario: string, viewport: { width: number; height: number }, frames: Frame[]) => {
    const drawn = frames.filter((frame) => frame.composer && frame.box);
    const first = drawn[0];
    const max: Record<string, Record<string, number>> = {};
    for (const part of PARTS) {
      max[part] = {};
      for (const edge of EDGES)
        max[part]![edge] = first
          ? Math.round(Math.max(0, ...drawn.map((frame) => Math.abs(frame[part]![edge] - first[part]![edge]))) * 10) /
            10
          : 0;
    }
    let changeFrames = 0;
    for (let i = 1; i < drawn.length; i++)
      if (PARTS.some((part) => EDGES.some((edge) => Math.abs(drawn[i]![part]![edge] - drawn[i - 1]![part]![edge]) > 1)))
        changeFrames += 1;
    const line = {
      engine,
      case: scenario,
      viewport: `${viewport.width}x${viewport.height}`,
      frames: drawn.length,
      change_frames: changeFrames,
      max_move_px: max,
      first: first ?? null,
      worst: drawn.reduce<Frame | null>((worst, frame) => {
        const off = (one: Frame | null) =>
          one && first ? Math.max(...PARTS.map((part) => Math.abs(one[part]!.top - first[part]!.top))) : -1;
        return off(frame) > off(worst) ? frame : worst;
      }, null),
    };
    console.log(`composer-anchored: ${JSON.stringify(line)}`);
    return line;
  };
  const expectStill = (line: ReturnType<typeof report>) => {
    expect(line.frames).toBeGreaterThan(10);
    for (const part of PARTS) for (const edge of EDGES) expect(line.max_move_px[part]![edge]).toBeLessThanOrEqual(1);
  };

  /// Each step changes something above the composer, in the page, then lets 20 frames paint.
  type Step = (page: Page) => Promise<unknown>;
  const inPage =
    <T>(fn: (arg: T) => unknown, arg: T): Step =>
    (page) =>
      // A generic T is not Unboxed<T> to playwright's types; the step functions take plain JSON.
      page.evaluate(fn as never, arg as never);
  const headerTo = (delta: number | null) =>
    inPage((delta) => {
      const header = document.querySelector<HTMLElement>(".acpmux-header")!;
      if (delta === null) {
        header.style.removeProperty("flex-basis");
        header.style.removeProperty("height");
        delete header.dataset.testBase;
        return;
      }
      header.dataset.testBase ??= String(header.getBoundingClientRect().height);
      const height = `${Number(header.dataset.testBase) + delta}px`;
      header.style.flexBasis = height;
      header.style.height = height;
    }, delta);
  const headerVar = (height: number | null) =>
    inPage((height) => {
      const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
      if (height === null) shell.style.removeProperty("--acpmux-header-height");
      else shell.style.setProperty("--acpmux-header-height", `${height}px`);
    }, height);
  const tabRow = (row: { height: number; trailingInset?: number }) =>
    inPage(
      (row) =>
        (
          window as {
            cmuxAcpmuxBridge?: { applyTabRow?(row: unknown): void };
          }
        ).cmuxAcpmuxBridge!.applyTabRow!(row),
      row,
    );
  /// A line of the header's own (the rolling summary's place, beside the chat's name, or leading the
  /// tools in the tab row) whose text grows from nothing to wider than the pane, and goes.
  const headerLine = (words: number | null) =>
    inPage((words) => {
      document.querySelector("[data-test-header-line]")?.remove();
      if (words === null) return;
      const header = document.querySelector<HTMLElement>(".acpmux-header")!;
      const holder = header.hasAttribute("data-tab-row")
        ? header.querySelector<HTMLElement>(".acpmux-handoff-header-tools")!
        : (header.firstElementChild as HTMLElement);
      const node = document.createElement("span");
      node.dataset.testHeaderLine = "";
      node.style.cssText = "display:flex;flex:0 1 auto;min-width:0;white-space:nowrap;overflow:hidden;line-height:26px";
      node.textContent = Array.from({ length: words }, (_, n) => `summary${n}`).join(" ");
      holder.insertBefore(node, holder.firstChild);
    }, words);
  /// A banner (the shared notice's markup) as the stage's first child, or after the header.
  const banner = (where: "top" | "under-header" | null) =>
    inPage((where) => {
      document.querySelector("[data-test-banner]")?.remove();
      if (!where) return;
      const stage = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-stage")!;
      const node = document.createElement("div");
      node.className = "ui-notice";
      node.dataset.testBanner = "";
      node.style.cssText = "flex:none;height:48px;padding:12px;box-sizing:border-box";
      node.textContent = "Stand-in banner at the top of the stage";
      stage.insertBefore(node, where === "top" ? stage.firstChild : stage.querySelector(".acpmux-header")!.nextSibling);
    }, where);
  /// The loading state's (ChatUnavailableState.tsx) markup over the stage in place of the transcript,
  /// or an unavailable card's; null puts the transcript back.
  const unavailable = (state: "connecting" | "notFound" | null) =>
    inPage((state) => {
      document.querySelector("[data-test-unavailable]")?.remove();
      const stage = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-stage")!;
      const hidden = [...stage.children].filter(
        (child) => child !== stage.querySelector(".acpmux-header") && !(child as HTMLElement).dataset.testBanner,
      ) as HTMLElement[];
      for (const child of hidden) child.style.display = state ? "none" : "";
      if (!state) return;
      const node = document.createElement("div");
      node.className = "acpmux-empty acpmux-unavailable";
      node.dataset.unavailable = state;
      node.dataset.testUnavailable = "";
      if (state === "notFound")
        node.innerHTML =
          '<p class="acpmux-empty-title acpmux-unavailable-title">This chat is not here</p><div class="acpmux-unavailable-copy"><p>It may be on another machine.</p><button type="button">Close Tab</button></div>';
      stage.appendChild(node);
    }, state);
  /// A row in view above the composer grows by `grow` px after it mounted (its late measure), or shrinks back.
  const rowGrows = (grow: number | null) =>
    inPage((grow) => {
      document.querySelector("[data-test-late]")?.remove();
      if (grow === null) return;
      const dock = document.querySelector<HTMLElement>(".acpmux-dock")!.getBoundingClientRect().top;
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].filter((row) => {
        const rect = row.getBoundingClientRect();
        return rect.top > 60 && rect.bottom < dock;
      });
      const row = rows.at(-2) ?? rows[0]!;
      const late = document.createElement("div");
      late.dataset.testLate = "";
      late.style.cssText = `height:${grow}px`;
      row.appendChild(late);
    }, grow);

  /// The chat's inspector (the pane's debug event view) over the stage: the stack goes from floating
  /// over the transcript into the pane's flow under it.
  const inspector = (open: boolean) => inPage((open) => window.cmuxAcpmuxBridge!.toggleInspector(open), open);
  /// A draft of `lines` lines in the composer, typed before the case records: a tall card a short pane
  /// clamps (bottomStack.css max-height).
  const typeDraft = async (page: Page, lines: number) => {
    await page.locator(".acpmux-composer-box [contenteditable]").first().click();
    await page.keyboard.type("draft");
    for (let n = 1; n < lines; n++) {
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type(`line ${n}`);
    }
  };
  const width = (page: Page, viewport: { width: number; height: number }, to: number) =>
    page.setViewportSize({ width: to, height: viewport.height });

  const CASES: Record<string, (viewport: { width: number; height: number }) => Step[]> = {
    header: () => [headerTo(0), headerTo(28), headerTo(60), headerTo(28), headerTo(0), headerTo(null)],
    "header-var": () => [headerVar(56), headerVar(88), headerVar(28), headerVar(null)],
    "tab-row": () => [
      tabRow({ height: 28, trailingInset: 40 }),
      tabRow({ height: 56, trailingInset: 40 }),
      tabRow({ height: 0 }),
    ],
    "header-line": () => [headerLine(3), headerLine(40), headerLine(400), headerLine(null)],
    "tab-row-line": () => [
      tabRow({ height: 28, trailingInset: 40 }),
      headerLine(3),
      headerLine(40),
      headerLine(400),
      headerLine(null),
      tabRow({ height: 0 }),
    ],
    banner: () => [banner("top"), banner(null), banner("under-header"), banner(null)],
    connecting: () => [unavailable("connecting"), unavailable(null), unavailable("connecting"), unavailable(null)],
    unavailable: () => [
      unavailable("notFound"),
      unavailable(null),
      unavailable("connecting"),
      unavailable("notFound"),
      unavailable(null),
    ],
    "connecting-draft": () => [
      unavailable("connecting"),
      unavailable(null),
      unavailable("connecting"),
      unavailable(null),
    ],
    inspector: () => [inspector(true), inspector(false), inspector(true), inspector(false)],
    "inspector-draft": () => [inspector(true), inspector(false)],
    "late-row": () => [rowGrows(28), rowGrows(60), rowGrows(null)],
    "width-only": (viewport) => [
      (page) => width(page, viewport, viewport.width - 140),
      (page) => width(page, viewport, viewport.width + 160),
      (page) => width(page, viewport, viewport.width),
    ],
  };
  const VIEWPORTS = [
    { width: 900, height: 700 },
    // A short pane: the dock's max-height clamps (bottomStack.css) are near.
    { width: 900, height: 380 },
  ];

  for (const viewport of VIEWPORTS)
    for (const [scenario, steps] of Object.entries(CASES))
      test.each(engines.map(([name]) => name))(
        `%s ${viewport.width}x${viewport.height}: ${scenario} above the composer moves it 0 px`,
        async (name) => {
          engine = name;
          const page = await pane.open(viewport);
          try {
            if (scenario.endsWith("-draft")) {
              await typeDraft(page, 14);
              await paint(page, 20);
            }
            await startRecording(page);
            await paint(page, 4);
            for (const step of steps(viewport)) {
              await step(page);
              await paint(page, 20);
            }
            expectStill(report(scenario, viewport, await stopRecording(page)));
          } finally {
            await page.close();
          }
        },
      );

  // A real cold open whose attach acpmux holds: the pane draws its header and empty stage with the
  // composer under it, then the chat's rows arrive above it. The composer holds from its first frame
  // to the chat's.
  for (const viewport of VIEWPORTS)
    test.each(engines.map(([name]) => name))(
      `%s ${viewport.width}x${viewport.height}: a held attach, then the chat arriving, moves the composer 0 px`,
      async (name) => {
        engine = name;
        const page = await browsers.get(name)!.newPage({ viewport });
        try {
          await installPaintedFrames(page);
          pane.stall(["_acpmux/attach"]);
          await page.goto(pane.address());
          await page.locator(".acpmux-composer-box").waitFor({ timeout: 60_000 });
          await pane.sent("_acpmux/attach", 0);
          await startRecording(page);
          await paint(page, 20);
          pane.stall([]);
          await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 60_000 });
          await paint(page, 60);
          expectStill(report("cold-open-held-attach", viewport, await stopRecording(page)));
        } finally {
          pane.stall([]);
          await page.close();
        }
      },
    );
});
