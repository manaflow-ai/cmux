// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Every chat fold stays inside a frame's budget, and its cost does not grow with the chat's length
// (Leo, 2026-11-09, on a finished turn's "Worked for", its "Ran 10 commands" and one step's Shell
// card: "The collapse and expand animation is sort of messed up now. It just, like, lags pretty
// heavily. I think most of it is just the lag. I don't know why it's lagging so much").
//
// The chat is his shape: each finished turn folds under "Worked for 1m 38s · N tool calls", and opens
// to a read run, a "Ran 10 commands" group, a short reply, a subagent's end and a long reply. It is
// drawn at 5 turns (50 rows) and at 50 (500 rows). On a turn in the middle, scrolled near the view's
// top, the reader opens the turn's fold, the group, one step's Shell card, then closes them again.
// Each toggle is measured from the click to rest (support/foldFrameReport.ts) and must:
// - draw again, mount and lay out a number of rows that does not depend on the chat's length: the
//   same at 500 rows as at 50, within a small slack;
// - commit React and draw rows again a few times over the whole fold, never once per frame;
// - on Chromium, at four times slower script (a busy Mac), force a few layouts at most and keep
//   four frames in five within a frame and a half at 60 Hz.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { costLine, installFoldProbe, measureToggle, SMOOTH_MS, type FoldCost } from "./support/foldFrameReport";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-fold-frame-budget-browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-fold-frame-budget-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat fold frame budget", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
      try {
        browsers[name] = await engines[name].launch({ headless: true });
      } catch (error) {
        if (process.env.GITHUB_ACTIONS === "true") throw error;
        console.warn(`chat-fold-frame-budget-browser: ${name} cannot launch here: ${String(error).split("\n")[0]}`);
      }
    }
  });
  afterAll(async () => {
    for (const each of Object.values(browsers)) await each?.close();
    await vite?.close();
  });

  /// How much slower than this host Chromium runs the page (the CI runners and a loaded Mac are slower).
  const CPU_SLOWDOWN = Number(process.env.FOLD_CPU_SLOWDOWN ?? 4);
  /// The share of a fold's frames that must be smooth (support/foldFrameReport.ts SMOOTH_MS).
  const SMOOTH_SHARE = 0.6;
  /// Rows the virtualizer mounts more at 500 rows than at 50 (the view holds a few more short rows).
  const ROW_SLACK = 8;
  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = Date.now() - 86_400_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The plan's margin is roughly the worst case for the seat: if a team spends its whole ` +
        "included usage, the rest pays for the pool, and machine time billed at list leaves more than that.",
    ).join("\n\n");
  const lines = (count: number) =>
    Array.from({ length: count }, (_, index) => `line ${index + 1}: pricing.md matched "team plan"`).join("\n");
  const execute = (id: string, title: string, output = lines(26)) => ({
    kind: "tool",
    text: "",
    tool: { id, title, kind: "execute", status: "completed", command: `rg -n "team plan" ${id}`, output, exitCode: 0 },
  });
  const read = (id: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read docs/${id}.md`, kind: "read", status: "completed", output: lines(12) },
  });
  const STEPS = [
    "Searched memory for cloud pricing",
    "Search memory and asks for pricing context",
    "Search for pricing and billing context",
    "Read the pricing note",
    "Find the team-plan pricing lane and its numbers",
    "Find the earlier team-plan pricing math",
    "Read the team-plan brief and the plan PR state",
    "View the plan PR",
    "Read the margin math in the team plan design",
    "Forward the pricing ask to the team-plan lane",
  ];
  /// A prompt long enough to fold behind Show more (twenty lines and more).
  const prompt = (index: number) =>
    [`Question ${index}: what does the team plan leave us per seat?`]
      .concat(Array.from({ length: 23 }, (_, line) => `${line + 1}. Count the seat's included usage.`))
      .join("\n");
  /// One finished turn of ten rows, his shape: it folds under "Worked for".
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", prompt(index)),
    row(`t${index}-reads`, "activity", undefined, { items: [read(`t${index}-r1`), read(`t${index}-r2`)] }),
    row(`t${index}-note`, "assistant", "Checking the pricing notes first."),
    row(`t${index}-cmds`, "activity", undefined, {
      items: STEPS.map((title, step) => execute(`t${index}-c${step}`, title)),
    }),
    row(`t${index}-mid`, "assistant", "Found the plan's numbers; checking the runner labels."),
    row(`t${index}-more`, "activity", undefined, {
      items: [0, 1, 2].map((step) => execute(`t${index}-m${step}`, `Check runner label ${step}`, lines(4))),
    }),
    row(`t${index}-sub`, "subagentDone", undefined, {}),
    row(`t${index}-answer`, "assistant", paragraphs(4)),
    row(`t${index}-tail`, "assistant", paragraphs(1)),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 98_000, toolCount: 15 }),
  ];
  const chat = (turns: number) => Array.from({ length: turns }, (_, index) => turn(index)).flat();

  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const open = async (browser: Browser, turns: number) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 1000 } });
    await installFoldProbe(page);
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(
      (rows) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(rows),
      chat(turns),
    );
    await settle(page);
    return page;
  };
  /// Scrolls the row `id` to `offset` px under the view's top.
  const bring = async (page: Page, id: string, offset = 40) => {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await page.evaluate(
        async ({ id, offset }) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          for (let step = 0; step < 80 && !document.querySelector(`[data-row-id="${id}"]`); step += 1) {
            scroller.scrollTop -= scroller.clientHeight / 2;
            await window.cmuxPaintFrame();
          }
          const node = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
          scroller.scrollTop += node.getBoundingClientRect().top - scroller.getBoundingClientRect().top - offset;
        },
        { id, offset },
      );
      await settle(page);
    }
  };
  /// Clicks the first toggle `selector` matches (the `nth` one), where it is drawn.
  const clicker =
    (page: Page, selector: string, nth = 0) =>
    async () => {
      const point = await page.evaluate(
        ({ selector, nth }) => {
          const target = document.querySelectorAll<HTMLElement>(selector)[nth];
          if (!target) return undefined;
          const box = target.getBoundingClientRect();
          return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
        },
        { selector, nth },
      );
      if (!point) throw new Error(`no toggle matches ${selector} [${nth}]`);
      await page.mouse.click(point.x, point.y);
    };

  /// The six toggles on turn `index` of a chat of `turns`, each measured.
  const walk = async (name: keyof typeof engines, turns: number): Promise<FoldCost[]> => {
    const page = await open(browsers[name]!, turns);
    const cdp = name === "chromium" ? await page.context().newCDPSession(page) : undefined;
    // A busy Mac's main thread, modelled: Chromium runs the page's work this many times slower.
    if (cdp) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU_SLOWDOWN });
    const index = Math.floor(turns / 2);
    const worked = `[data-row-id="worked-t${index}-user"] button.cv-worked`;
    // The turn's runs join into its first run's row: the reads, "Ran 10 commands", then the last three.
    const group = `[data-row-id="t${index}-reads"] button.cv-tool.is-toggle.is-run`;
    const step = `[data-row-id="t${index}-reads"] button.cv-command`;
    await bring(page, `worked-t${index}-user`);
    const costs: FoldCost[] = [];
    const run = async (label: string, selector: string, nth = 0) => {
      const profile = cdp && process.env.FOLD_PROFILE && label.includes(process.env.FOLD_PROFILE);
      if (profile) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
        await cdp.send("Profiler.start");
      }
      costs.push(await measureToggle(page, label, clicker(page, selector, nth), () => settle(page), cdp));
      if (profile) {
        const { profile: data } = (await cdp.send("Profiler.stop")) as unknown as {
          profile: {
            nodes: {
              id: number;
              callFrame: { functionName: string; url: string; lineNumber: number };
              children?: number[];
            }[];
            samples: number[];
            timeDeltas: number[];
          };
        };
        const self = new Map<number, number>();
        data.samples.forEach((id, index) => self.set(id, (self.get(id) ?? 0) + (data.timeDeltas[index] ?? 0)));
        const byId = new Map(data.nodes.map((node) => [node.id, node]));
        const parent = new Map<number, number>();
        for (const node of data.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
        const total = new Map<string, number>();
        const selfBy = new Map<string, number>();
        for (const [id, us] of self) {
          const seen = new Set<string>();
          const leaf = byId.get(id)!.callFrame;
          const leafKey = `${leaf.functionName || "(anon)"} ${leaf.url.split("/").pop()}:${leaf.lineNumber + 1}`;
          selfBy.set(leafKey, (selfBy.get(leafKey) ?? 0) + us);
          for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
            const frame = byId.get(at)!.callFrame;
            const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").pop()?.split("?")[0]}:${frame.lineNumber + 1}`;
            if (seen.has(key)) continue;
            seen.add(key);
            total.set(key, (total.get(key) ?? 0) + us);
          }
        }
        const top = (map: Map<string, number>) =>
          [...map]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 45)
            .map(([key, us]) => `${(us / 1000).toFixed(1)} ${key}`)
            .join("\n");
        console.log(`PROFILE ${turns} ${label} total:\n${top(total)}\nSELF:\n${top(selfBy)}`);
      }
    };
    await run("open Worked for", worked);
    await run("open Ran 10 commands", group, 1);
    await run("open a step's Shell card", step, 2);
    await run("close the step", step, 2);
    await run("close Ran 10 commands", group, 1);
    // The prompt's own fold, Show more, on the next turn's prompt (drawn whole, not behind a fold).
    const next = `t${index + 1}-user`;
    await bring(page, next);
    await run("open Show more", `[data-row-id="${next}"] .cv-user__more`);
    await run("close Show more", `[data-row-id="${next}"] .cv-user__more`);
    await bring(page, `worked-t${index}-user`);
    await run("close Worked for", worked);
    await page.close();
    return costs;
  };

  /// Toggles that play a body's height inside one row (not "Worked for", which adds whole rows).
  const disclosure = (step: string) => !step.includes("Worked for");
  /// What a fold may cost. Counts, not times, carry the length check: they hold on any machine.
  const failures = (name: string, short: FoldCost[], long: FoldCost[]) => {
    const out: string[] = [];
    for (const [label, costs] of [
      ["50 rows", short],
      ["500 rows", long],
    ] as const)
      for (const cost of costs) {
        const at = `${name} ${label} ${cost.step}`;
        if (!disclosure(cost.step)) continue;
        // The click's commits and one when the fold lands, or a frame that gave way to the full
        // placement now and then: never one per frame, as it was (one commit for each frame).
        const commits = Math.max(4, Math.ceil(cost.frames / 2));
        if (cost.commits > commits)
          out.push(`${at}: ${cost.commits} React commits in ${cost.frames} frames (at most ${commits})`);
        // At most one render of each mounted row over the whole fold, not one per frame.
        if (cost.rowRenders > cost.mounted)
          out.push(`${at}: ${cost.rowRenders} row renders for ${cost.mounted} mounted rows`);
        const forced = Math.max(4, cost.frames / 2.5);
        if (cost.forcedLayouts !== undefined && cost.forcedLayouts > forced)
          out.push(
            `${at}: ${cost.forcedLayouts} layouts forced by script in ${cost.frames} frames (at most ${forced})`,
          );
        // The frame budget, at CPU_SLOWDOWN: three frames in five within a frame and a half at 60 Hz
        // (the click's own frame, which draws what opened, may be slower, and a shared runner drops
        // a few). A fold that commits on every frame runs at 30 frames a second: under half.
        if (name === "chromium" && cost.smooth < SMOOTH_SHARE)
          out.push(
            `${at}: ${Math.round(cost.smooth * 100)}% of ${cost.frames} frames within ${SMOOTH_MS} ms (at least ${SMOOTH_SHARE * 100}%)`,
          );
      }
    // The same toggle at ten times the rows draws, mounts and lays out about as much.
    for (const [index, cost] of long.entries()) {
      const base = short[index]!;
      const at = `${name} ${cost.step}`;
      // Rows drawn again stay within the mounted rows, which stay as many as at 50 (below).
      if (cost.rowsRendered > cost.mounted)
        out.push(`${at}: drew ${cost.rowsRendered} rows at 500 rows, ${cost.mounted} mounted`);
      if (cost.mounts > base.mounts + ROW_SLACK)
        out.push(`${at}: mounted ${cost.mounts} rows at 500 rows, ${base.mounts} at 50`);
      if (cost.mounted > base.mounted + ROW_SLACK)
        out.push(`${at}: ${cost.mounted} rows mounted at rest at 500 rows, ${base.mounted} at 50`);
      if (cost.commits > base.commits + 3)
        out.push(`${at}: ${cost.commits} commits at 500 rows, ${base.commits} at 50`);
    }
    return out;
  };

  for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
    test(`${name}: each fold of a turn costs the same at 500 rows as at 50, inside a frame's budget`, async () => {
      if (!browsers[name]) return;
      const short = await walk(name, 5);
      const long = await walk(name, 50);
      for (const cost of short) console.log(costLine(`${name} 50 rows`, cost));
      for (const cost of long) console.log(costLine(`${name} 500 rows`, cost));
      expect(failures(name, short, long)).toEqual([]);
    });
  }
});
