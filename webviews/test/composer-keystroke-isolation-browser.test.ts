// cmux-web-test-timeout: 420
// l10n-allow-file: typed test keys, not shipped UI.
// A keystroke in the agent chat's prompt is the browser's own text edit and the composer's render,
// nothing else: no React component outside the composer commits, and no layout starts outside the
// composer's box (Leo, 2026-11-17: "why should typing... wait on rendering??? why should typing
// even cause rendering"; "typing is still slow in the composer in this version").
//
// composer-keystroke-renders-browser.test.ts counts the components that carry an `acpmuxPerf.render`
// counter (the pane root, the transcript, rows, two composer parts). This file counts every one: a
// React DevTools hook installed before the page's code sees each commit, walks the fibers that
// rendered in it (mounted, or did work this commit), and names each one outside the composer's
// subtree (ComposerFrame and what it renders, portals included). A Chromium trace over the same keys
// names every element a key marked as needing layout: one outside the composer's form means a key
// reflowed the pane.
//
// Two windows on a 1,500-row chat built as it ships (production React, React Compiler on; unminified
// so the report names components):
//   idle    every commit in the window is the keys': none may render outside the composer.
//   growth  Shift-Return lines grow the box, followed and scrolled up: at most one transcript commit a line (a ratchet).
//   stream  a reply streams (loadRun) while the keys are typed: what the same stream renders outside
//           the composer with nobody typing (run first) is allowed; anything more is the keys'.
//           Production React hands the hook no commit priority, so the keys' commits cannot be told
//           from the stream's that way.
// Pattern page: cmuxterm-hq docs/handbook/keystroke-renders-only-the-composer.md.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-keystroke-isolation-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type Commit = { at: number; inside: number; outside: string[] };

await requireBrowserLane("composer-keystroke-isolation-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-keystroke-isolation-browser", "chromium", chromium))) return;
  setDefaultTimeout(400_000);

  /// Init script, self-contained: a DevTools hook that records, per commit, the components that rendered
  /// outside the composer and how many rendered inside it.
  function installCommitWatch() {
    type Fiber = {
      tag: number;
      type: any;
      elementType: any;
      flags: number;
      child: Fiber | null;
      sibling: Fiber | null;
      alternate: Fiber | null;
    };
    type Commit = { at: number; inside: number; outside: string[] };
    const w = window as any;
    const commits: Commit[] = [];
    w.__keystrokeCommits = commits;
    // Function, class, forwardRef, memo, simple memo components: the ones that run code on a render.
    const COMPONENT = new Set([0, 1, 11, 14, 15]);
    const PERFORMED_WORK = 1;
    const nameOf = (fiber: Fiber) => {
      const type = fiber.type ?? fiber.elementType;
      if (!type) return `tag${fiber.tag}`;
      return (
        type.displayName ||
        type.name ||
        type.render?.displayName ||
        type.render?.name ||
        type.type?.displayName ||
        type.type?.name ||
        `tag${fiber.tag}`
      );
    };
    const COMPOSER = /^(Composer|ComposerFrame|MemoComposer)(\$\d+)?$/;
    let renderers = 0;
    w.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      supportsFiber: true,
      isDisabled: false,
      renderers: new Map(),
      inject(internals: unknown) {
        renderers += 1;
        this.renderers.set(renderers, internals);
        return renderers;
      },
      checkDCE() {},
      onScheduleFiberRoot() {},
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      onCommitFiberRoot(_id: number, root: { current: Fiber }) {
        const commit: Commit = { at: performance.now(), inside: 0, outside: [] };
        // Depth-first over the subtrees this commit touched: a fiber whose children are the previous
        // tree's own bailed out whole, and nothing under it rendered.
        const stack: [Fiber, boolean][] = [];
        const top = root.current;
        if (top.child) stack.push([top.child, false]);
        while (stack.length) {
          const [fiber, insideParent] = stack.pop()!;
          if (fiber.sibling) stack.push([fiber.sibling, insideParent]);
          const component = COMPONENT.has(fiber.tag);
          const inside = insideParent || (component && COMPOSER.test(nameOf(fiber)));
          const previous = fiber.alternate;
          if (component && (previous === null || (fiber.flags & PERFORMED_WORK) !== 0)) {
            if (inside) commit.inside += 1;
            else commit.outside.push(nameOf(fiber));
          }
          if (fiber.child && (previous === null || fiber.child !== previous.child)) stack.push([fiber.child, inside]);
        }
        if (commit.inside || commit.outside.length) commits.push(commit);
      },
    };
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const KEYS = 16;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-keystroke-isolation-"));
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      // Unminified: the report names components. Same React (production) and compiler pass.
      build: { outDir: out, emptyOutDir: true, minify: false },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });

  async function openChat(): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.addInitScript(installCommitWatch);
    await page.goto(`http://127.0.0.1:${statics!.port!}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }))) as {
      rows?: number;
      error?: string;
    };
    expect(seeded.error).toBeUndefined();
    expect(seeded.rows ?? 0).toBeGreaterThan(1000);
    const prompt = page.locator(PROMPT).first();
    await prompt.waitFor({ timeout: 30_000 });
    await prompt.click();
    // The first keys load the composer's lazy parts (emoji data, the mention index).
    for (const key of "warm") await page.keyboard.press(key);
    await shows(page, "warm");
    for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
    await shows(page, "");
    // Debounced work the warm-up keys started (a draft save, a suggestion index) lands before the window.
    // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
    await page.waitForTimeout(1_500);
    await settled(page);
    return page;
  }
  const shows = (page: Page, text: string) =>
    page.waitForFunction(
      ([selector, want]) => {
        const shown = (document.querySelector(selector!)?.textContent ?? "").trim();
        return want === "" ? !shown.includes("warm") : shown === want;
      },
      [PROMPT, text] as const,
    );
  // Two frames after the last change: every render the key started has committed.
  const settled = (page: Page) =>
    page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));

  /// Types KEYS letters, each waited on until it shows, then waits out the keys' debounced and idle
  /// work; returns the commits in that window.
  async function typeKeys(page: Page): Promise<Commit[]> {
    const since = (await page.evaluate(() => performance.now())) as number;
    const typed = "abcdefghijklmnop".slice(0, KEYS);
    for (let i = 0; i < typed.length; i += 1) {
      await page.keyboard.press(typed[i]!);
      await shows(page, typed.slice(0, i + 1));
      // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
      await page.waitForTimeout(60);
    }
    // Past the composer's draft-save debounce: work a key defers still counts as the key's.
    // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
    await page.waitForTimeout(1_500);
    await settled(page);
    return (await page.evaluate(
      (from) => ((window as any).__keystrokeCommits as Commit[]).filter((commit) => commit.at >= from),
      since,
    )) as Commit[];
  }

  /// Components that render on their own clock, never a key's: a message's age (MessageTime,
  /// clock.ts `useLabelClock`) turns over at the minute for every label in view, in one commit with
  /// none of their parents. A commit made of those alone is the clock's, wherever the window falls
  /// (2026-11-18: a scrolled-up growth window crossed a minute and drew 31 MessageTime). A key that
  /// rendered a label would render its row with it, and still counts.
  const CLOCK_ONLY = new Set(["MessageTime"]);
  const byKey = (commit: Commit) => commit.outside.length > 0 && !commit.outside.every((name) => CLOCK_ONLY.has(name));
  const outsideOf = (commits: Commit[]) => {
    const counts = new Map<string, number>();
    for (const commit of commits)
      if (byKey(commit)) for (const name of commit.outside) counts.set(name, (counts.get(name) ?? 0) + 1);
    return Object.fromEntries([...counts.entries()].sort((a, b) => b[1] - a[1]));
  };

  /// Every element marked as needing layout in the window (Chromium's LayoutInvalidationTracking: one
  /// event per element whose layout a change dirtied, with the reason), by whether it lies in the
  /// composer's form. A layout's root is the document whatever it lays out, so roots cannot say what
  /// a key reflowed; the elements it dirtied can.
  async function layoutDirtied(page: Page, run: () => Promise<unknown>) {
    const cdp = await page.context().newCDPSession(page);
    await browser.startTracing(page, {
      categories: [
        "devtools.timeline",
        "disabled-by-default-devtools.timeline",
        "disabled-by-default-devtools.timeline.invalidationTracking",
      ],
    });
    await run();
    const raw = JSON.parse((await browser.stopTracing()).toString()) as {
      traceEvents: { name: string; ph: string; args?: any }[];
    };
    const ids: number[] = [];
    const reasons = new Map<number, string>();
    let layouts = 0;
    let dirtyObjects = 0;
    for (const event of raw.traceEvents) {
      if (event.name === "Layout" && (event.ph === "B" || event.ph === "X")) {
        layouts += 1;
        dirtyObjects += Number(event.args?.beginData?.dirtyObjects ?? 0);
      }
      if (event.name !== "LayoutInvalidationTracking") continue;
      const data = event.args?.data ?? {};
      if (typeof data.nodeId !== "number") continue;
      // A node the edit removed (the editor's old text node, its trailing break) is gone from the
      // document by the time it is resolved, so it cannot be placed; its parent's own "Text changed"
      // or "Added to layout" event says where the layout happened.
      if (data.reason === "Removed from layout") continue;
      ids.push(data.nodeId);
      reasons.set(data.nodeId, String(data.reason ?? ""));
    }
    await cdp.send("DOM.getDocument", { depth: 0 });
    const where = new Map<string, number>();
    let outside = 0;
    for (const backendNodeId of ids) {
      let label = "unresolved";
      let inside = false;
      try {
        const { object } = (await cdp.send("DOM.resolveNode", { backendNodeId })) as { object: { objectId: string } };
        const { result } = (await cdp.send("Runtime.callFunctionOn", {
          objectId: object.objectId,
          returnByValue: true,
          functionDeclaration: `function () {
            const el = this.nodeType === 1 ? this : this.parentElement;
            const form = document.querySelector("form.acpmux-composer");
            const cls = el && typeof el.className === "string" ? el.className.split(/\\s+/).filter(Boolean).slice(0, 2) : [];
            const label = el ? [el.tagName.toLowerCase(), ...cls].join(".") : String(this.nodeName);
            const inside = !!(form && el && form.contains(el));
            // Outside the composer, name the ancestors too: a bare "span" says nothing.
            const up = [];
            for (let at = el && el.parentElement; !inside && at && up.length < 4; at = at.parentElement)
              up.push(at.tagName.toLowerCase() + (typeof at.className === "string" && at.className ? "." + at.className.split(" ")[0] : ""));
            // The page's own key-presentation probe (keyPresentation.ts: a one-pixel, contained, fixed glyph a measuring
            // page adds to the body for each key) is the instrument, not the app: it lays out nothing outside itself.
            const probe = !!(el && el.hasAttribute("elementtiming"));
            return { inside: inside || probe, detached: !this.isConnected, label: up.length ? label + " < " + up.join(" < ") : label };
          }`,
        })) as { result: { value: { inside: boolean; detached: boolean; label: string } } };
        // A node the edit added and then replaced in the same window (ProseMirror swaps a text node on
        // the next key) is out of the document by now: no layout happened outside, as with the removed
        // ones above.
        if (result.value.detached) continue;
        inside = result.value.inside;
        label = result.value.label;
      } catch {
        // A node gone by now (a row shed): outside, named as unresolved.
      }
      if (!inside) outside += 1;
      const key = `${inside ? "in" : "out"}:${label} (${reasons.get(backendNodeId) ?? ""})`;
      where.set(key, (where.get(key) ?? 0) + 1);
    }
    await cdp.detach();
    return { layouts, dirtyObjects, dirtied: ids.length, outside, where: Object.fromEntries(where) };
  }

  test("idle: a key commits nothing outside the composer and lays out nothing outside it", async () => {
    const page = await openChat();
    let commits: Commit[] = [];
    const layout = await layoutDirtied(page, async () => {
      commits = await typeKeys(page);
    });
    await page.close();
    const inside = commits.reduce((total, commit) => total + commit.inside, 0);
    const report = {
      keys: KEYS,
      commits: commits.length,
      composer_renders: inside,
      outside: outsideOf(commits),
      layout,
    };
    console.log(`KEYSTROKE-ISOLATION idle ${JSON.stringify(report)}`);
    // The hook saw the composer draw the keys: the watch works on this React.
    expect(inside).toBeGreaterThanOrEqual(KEYS);
    expect(report.outside).toEqual({});
    expect({ layoutDirtiedOutsideComposer: layout.outside, where: layout.where }).toEqual({
      layoutDirtiedOutsideComposer: 0,
      where: Object.fromEntries(Object.entries(layout.where).filter(([key]) => key.startsWith("in:"))),
    });
  });

  // A ratchet, not yet the rule: a line that grows the composer renders the transcript at most once,
  // never the pane root, followed and scrolled up. Since #45791 the list takes the growth's room in one
  // ordinary render after the frame the growth starts in (never in the key's task); measured 2026-11-18
  // on that head: 3 lines, 2 transcript commits (TranscriptView, rows, the minimaps, Jump to latest),
  // followed and scrolled up alike. Zero needs the room out of React state without breaking #45791's
  // one owner (composer-wrap-one-owner.test.ts); a refs-only room did reach zero and broke it. Followed,
  // the latest row keeps its gap over the grown card.
  for (const scrolled of [false, true])
    test(`growth${scrolled ? ", scrolled up" : ""}: a new line renders the transcript at most once, never the pane`, async () => {
      const page = await openChat();
      if (scrolled) {
        await page.mouse.move(550, 300);
        await page.mouse.wheel(0, -1_200);
        // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
        await page.waitForTimeout(800);
        await settled(page);
        await page.locator(PROMPT).first().click();
        // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
        await page.waitForTimeout(300);
      }
      // The latest drawn row's foot against the composer's top: the gap the lift keeps.
      const gap = async () =>
        (await page.evaluate(() => {
          const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-thread > *")];
          const foot = Math.max(...rows.map((row) => row.getBoundingClientRect().bottom));
          return (document.querySelector("form.acpmux-composer")?.getBoundingClientRect().top ?? 0) - foot;
        })) as number;
      const gapBefore = await gap();
      await settled(page);
      const since = (await page.evaluate(() => performance.now())) as number;
      const box = async () =>
        (await page.evaluate(
          () => document.querySelector("form.acpmux-composer")?.getBoundingClientRect().height ?? 0,
        )) as number;
      const before = await box();
      const layout = await layoutDirtied(page, async () => {
        for (let line = 0; line < 3; line += 1) {
          await page.keyboard.press("x");
          await page.keyboard.press("Shift+Enter");
          // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
          await page.waitForTimeout(400);
        }
        // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
        await page.waitForTimeout(1_500);
        await settled(page);
      });
      const after = await box();
      const gapAfter = await gap();
      const commits = (await page.evaluate(
        (from) => ((window as any).__keystrokeCommits as Commit[]).filter((commit) => commit.at >= from),
        since,
      )) as Commit[];
      await page.close();
      const report = {
        scrolled,
        grew_px: Math.round(after - before),
        gap_before: Math.round(gapBefore * 10) / 10,
        gap_after: Math.round(gapAfter * 10) / 10,
        commits: commits.length,
        commits_outside: commits.filter(byKey).length,
        clock_commits: commits.filter((commit) => commit.outside.length > 0 && !byKey(commit)).length,
        outside: outsideOf(commits),
        layout,
      };
      console.log(`KEYSTROKE-ISOLATION growth ${JSON.stringify(report)}`);
      // The box grew: the lines took.
      expect(after - before).toBeGreaterThan(10);
      const LINES = 3;
      expect(report.commits_outside).toBeLessThanOrEqual(LINES);
      expect(report.outside.AcpmuxPane ?? 0).toBe(0);
      expect(report.outside.TranscriptView ?? 0).toBeLessThanOrEqual(LINES);
      // Followed, the rows rose with the card: the latest row rests the same gap over it.
      if (!scrolled) expect(Math.abs(gapAfter - gapBefore)).toBeLessThanOrEqual(1);
    });

  test("streaming: typing renders nothing outside the composer that the stream alone does not", async () => {
    const page = await openChat();
    // The stream alone first: what it renders outside the composer with nobody typing.
    const controlFrom = (await page.evaluate(() => performance.now())) as number;
    const control = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 3, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
    )) as Record<string, any>;
    const controlCommits = (await page.evaluate(
      (from) => ((window as any).__keystrokeCommits as Commit[]).filter((commit) => commit.at >= from),
      controlFrom,
    )) as Commit[];
    const streamed = new Set(controlCommits.flatMap((commit) => commit.outside));
    const streaming = page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 6, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
    );
    // fixed-wait: the window is time itself (a debounce, a key cadence or a settle past a commit), measured as it runs
    await page.waitForTimeout(400);
    const commits = await typeKeys(page);
    const run = (await streaming) as Record<string, any>;
    await page.close();
    const all = outsideOf(commits);
    const report = {
      keys: KEYS,
      deltas: run.deltas,
      control_deltas: control.deltas,
      commits: commits.length,
      composer_renders: commits.reduce((total, commit) => total + commit.inside, 0),
      // A commit that drew the composer and something else: the key's render rode one batch with
      // other work (a stream update), so the letter waited for that work.
      composer_commits_shared: commits.filter((commit) => commit.inside > 0 && commit.outside.length > 0).length,
      outside_typing_adds: Object.fromEntries(Object.entries(all).filter(([name]) => !streamed.has(name))),
      outside_all: all,
      stream_alone_outside: outsideOf(controlCommits),
    };
    console.log(`KEYSTROKE-ISOLATION stream ${JSON.stringify(report)}`);
    expect(run.deltas).toBeGreaterThan(50);
    expect(report.composer_renders).toBeGreaterThanOrEqual(KEYS);
    expect(report.outside_typing_adds).toEqual({});
  });
});
