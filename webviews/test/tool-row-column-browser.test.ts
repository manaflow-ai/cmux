// Tool rows share one column (Leo, 2026-10-31: "WHY IS THERE PRETOOLUSE", "WHY IS IT ALGINED SO
// [...] SHIT", "WHY IS IT RENDERED SO SHIT", "why are these indented for no reason"): a commands
// group holding a call a hook blocked, one that failed and one that went on in the background,
// beside lone rows. Every row's glyph and words start at the same x, every step shows its glyph, a
// verb is followed by one space, and a hook's block says "blocked by hook" with no "PreToolUse" until
// it is opened. For Codex parity a status word and a cause line draw nothing: they stay for screen
// readers only, out of the row's flow. All displayed content is synthetic.
//
// The two live cases of the mixed run test the `runs` arm of live-turn-work, not the shipped `line` arm:
// their calls are finished calls of a turn that still runs, which only `runs` draws
// (support/liveTurnRuns.ts). The other cases take the shipped arms.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { pinArms } from "./support/pinArms";
import { pinLiveTurnRuns } from "./support/liveTurnRuns";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("tool-row-column-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmViteServer(vite, "/test/browser/tool-row-column.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["dark", "light"] as const)
    for (const width of [760, 420] as const) {
      test(`${theme} ${width}px: tool rows share one glyph and text column, and a hook's block reads plainly`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 700 }, deviceScaleFactor: 2 });
        try {
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}/test/browser/tool-row-column.html?theme=${theme}&width=${width}`);
          await page.locator(".cv-steps .cv-tool").nth(2).waitFor();
          await page.evaluate(() => document.fonts.ready);
          const m = await page.evaluate(() => {
            const column = document.querySelector("[data-fixture-column]")!.getBoundingClientRect();
            const rows = [...document.querySelectorAll<HTMLElement>("[data-fixture-column] .cv-tool")].map((row) => {
              const icon = row.querySelector(".cv-tool__icon")!.getBoundingClientRect();
              const words = row.querySelector(".cv-tool__text, .cv-command__text")!;
              // The words' first glyph: a range over the first text, so a span's padding never counts.
              const walker = document.createTreeWalker(words, NodeFilter.SHOW_TEXT);
              let first = walker.nextNode();
              while (first && !first.textContent!.trim()) first = walker.nextNode();
              const range = document.createRange();
              range.setStart(first!, first!.textContent!.search(/\S/));
              range.setEnd(first!, first!.textContent!.search(/\S/) + 1);
              const box = row.getBoundingClientRect();
              const status = row.querySelector<HTMLElement>(".cv-command__failed, .cv-tool__failed");
              const statusStyle = status && !status.querySelector("svg") ? getComputedStyle(status) : undefined;
              return {
                text: row.textContent,
                iconLeft: icon.left - column.left,
                textLeft: range.getBoundingClientRect().left - column.left,
                right: box.right - column.right,
                status: status?.textContent?.trim(),
                // A status word is read aloud and never drawn: out of the flow, clipped away whole.
                statusShown: statusStyle
                  ? !(statusStyle.position === "absolute" && statusStyle.clipPath === "inset(50%)")
                  : false,
              };
            });
            // "Ran <command>": the command starts one space after the verb, never in a wide column.
            const verbGaps = [...document.querySelectorAll<HTMLElement>(".cv-command__text")].flatMap((words) => {
              const code = words.querySelector(".cv-command__line");
              if (!code) return [];
              const walker = document.createTreeWalker(words, NodeFilter.SHOW_TEXT);
              const verb = walker.nextNode()!;
              const range = document.createRange();
              range.selectNodeContents(verb);
              const ran = verb.textContent!.trimEnd();
              range.setEnd(verb, ran.length);
              return [code.getBoundingClientRect().left - range.getBoundingClientRect().right];
            });
            // A line under a row (a failure's cause) is read aloud and never drawn.
            const under = [...document.querySelectorAll<HTMLElement>("[data-fixture-column] .cv-tool-error")].map(
              (line) => {
                const style = getComputedStyle(line);
                return style.position === "absolute" && style.clipPath === "inset(50%)";
              },
            );
            return {
              guide: (() => {
                const group = document.querySelector(".cv-tool-group.is-flat.cv-steps")!;
                const style = getComputedStyle(group, "::before");
                const bounds = group.getBoundingClientRect();
                const row = group.closest(".acpmux-row")!;
                const clip = row.getBoundingClientRect();
                const icon = group.querySelector(".cv-tool__icon")!.getBoundingClientRect();
                const words = group.querySelector(".cv-command__text")!.getBoundingClientRect();
                const left = bounds.left + parseFloat(style.left);
                const right = left + parseFloat(style.width);
                return {
                  content: style.content,
                  width: parseFloat(style.width),
                  contain: getComputedStyle(row).contain,
                  insidePaintBounds:
                    left >= clip.left && right <= clip.right && bounds.top >= clip.top && bounds.bottom <= clip.bottom,
                  insideColumnGap: left > icon.right && right < words.left,
                  color: style.backgroundColor,
                };
              })(),
              stepIcons: [...document.querySelectorAll(".cv-steps > .cv-step > .cv-tool > .cv-tool__icon")].map(
                (icon) => getComputedStyle(icon).visibility,
              ),
              headerIcon: getComputedStyle(
                document.querySelector(".cv-tool.is-run > .cv-tool__icon, .cv-tool[aria-expanded] > .cv-tool__icon")!,
              ).visibility,
              rows,
              verbGaps,
              under,
              columnText: document.querySelector("[data-fixture-column]")!.textContent ?? "",
            };
          });
          console.log(`TOOL_ROW_COLUMN ${JSON.stringify({ theme, width, ...m })}`);
          expect(errors).toEqual([]);
          // An opened run draws with no guide line (Leo, 2026-11-03), and its steps show their glyphs,
          // as Codex draws them (Codex parity), their words on the header's text column (checked with
          // every row below).
          expect(m.guide.content).toBe("none");
          expect(m.stepIcons.length).toBe(3);
          for (const visibility of m.stepIcons) expect(visibility).toBe("visible");
          expect(m.headerIcon).toBe("visible");
          // The lone read, the group line, its three steps, the lone failed command, the lone block.
          expect(m.rows.length).toBe(7);
          const icon = m.rows[0]!.iconLeft;
          const text = m.rows[0]!.textLeft;
          for (const row of m.rows) {
            expect(Math.abs(row.iconLeft - icon), `icon x: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(Math.abs(row.textLeft - text), `text x: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(row.right, `right edge: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(row.statusShown, `status drawn: ${row.text}`).toBe(false);
          }
          // A hook's block: its plain status on the row, no "PreToolUse" and no line of its words.
          expect(m.columnText).not.toContain("PreToolUse");
          expect(m.columnText).not.toContain("fixture guard");
          // A blocked merge says no outcome: its row reads as its line, never "Merged PR #101".
          expect(m.columnText).not.toContain("Merged");
          expect(m.rows.filter((row) => row.status === "blocked by hook").length).toBe(2);
          // The failed calls keep their word for screen readers, and the lone one its cause.
          expect(m.rows.some((row) => row.status === "Exit 1")).toBe(true);
          expect(m.under.length).toBeGreaterThan(0);
          for (const hidden of m.under) expect(hidden).toBe(true);
          expect(m.verbGaps.length).toBeGreaterThan(0);
          for (const gap of m.verbGaps) {
            expect(gap).toBeGreaterThan(0);
            expect(gap).toBeLessThan(8);
          }
          // A thought's text starts at its label's words, with no guide line, opened (under the brain
          // glyph's row, on the tools' text column) and while it streams.
          await page.locator('[data-fixture-thoughts] button[aria-expanded="false"]').click();
          await page.locator("[data-fixture-thoughts] .cv-thought__body").waitFor();
          const thoughts = await page.evaluate(() => {
            const first = (node: Element) => {
              const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
              let text = walker.nextNode();
              while (text && !text.textContent!.trim()) text = walker.nextNode();
              const range = document.createRange();
              range.setStart(text!, text!.textContent!.search(/\S/));
              range.setEnd(text!, text!.textContent!.search(/\S/) + 1);
              return range.getBoundingClientRect().left;
            };
            const root = document.querySelector("[data-fixture-thoughts]")!;
            return [
              root.querySelector(".cv-thought__body")!,
              root.querySelector(".cv-thought.is-full .cv-thought__text")!,
            ].map((text) => {
              const label = text.closest("[data-thought]")!.querySelector(".cv-thought__label")!;
              return {
                guide: getComputedStyle(text).boxShadow,
                offset: first(text) - first(label),
              };
            });
          });
          expect(thoughts.length).toBe(2);
          for (const thought of thoughts) {
            expect(thought.guide).toBe("none");
            expect(Math.abs(thought.offset)).toBeLessThanOrEqual(0.5);
          }
          // Opened, the blocked call shows the hook's words as its output, without the envelope.
          await page.locator('[data-tool-id="blocked-lone"]').click();
          await page.locator(".cv-shell, pre").first().waitFor();
          const opened = await page.evaluate(() => document.querySelector("[data-fixture-column]")!.textContent ?? "");
          expect(opened).toContain("the fixture guard needs a passing review");
          expect(opened).not.toContain("PreToolUse");
          expect(opened).not.toContain("hook error");
        } finally {
          await page.close();
        }
      });
    }
  for (const [theme, harness, working] of [
    ["light", "claude", false],
    ["dark", "codex", false],
    ["dark", "claude", true],
    ["light", "codex", true],
  ] as const)
    test(`mixed ${theme} ${harness} ${working ? "live" : "finished"} run has one step per call, shared columns and useful drill-in`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 1000 } });
      try {
        // A running turn draws its finished runs under liveTurnWork.experiment.ts `runs` (shipped)
        // only; `line` draws none (live-turn-one-line.test.ts). Pinned, so the default can move.
        if (working) await pinArms(page, { "live-turn-work": "runs" });
        const port = (vite.httpServer!.address() as { port: number }).port;
        if (working) await pinLiveTurnRuns(page);
        await page.goto(
          `http://127.0.0.1:${port}/test/browser/tool-row-column.html?fixture=mixed&theme=${theme}&width=760&harness=${harness}&working=${working ? 1 : 0}`,
        );
        const fixture = page.locator("[data-fixture-mixed]");
        // Live or finished, the run is one folded line, as the Codex app draws a finished run while the
        // turn still runs (Lucas, 2026-11-11); a click opens it.
        await fixture.getByRole("button", { name: "Ran 2 commands and used 3 tools" }).click();
        // A finished call stays in its run while the live line reads Thinking (#37635): live or
        // finished, the run lists every call, each on its own row.
        const steps = fixture.locator("[data-mixed-tool-steps]");
        const step = ":scope > .cv-step > .cv-tool";
        await expect(steps.locator(":scope > .cv-step").count()).resolves.toBe(5);
        expect(await steps.locator(".is-run").count()).toBe(0);
        const geometry = await steps.locator(step).evaluateAll((rows) =>
          rows.map((row) => ({
            // A lone call with a picture draws in its visual's block (`.cv-tool-with-visual`): the
            // block is the row on the pitch. In an opened run every call is a step.
            top: (row.closest(".cv-tool-with-visual") ?? row).getBoundingClientRect().top,
            text: row.querySelector(".cv-tool__text, .cv-command__text")!.getBoundingClientRect().left,
            icon: getComputedStyle(row.querySelector(".cv-tool__icon")!).visibility,
          })),
        );
        for (let at = 0; at < geometry.length; at++) {
          expect(geometry[at]!.icon).toBe("visible");
          expect(Math.abs(geometry[at]!.text - geometry[0]!.text)).toBeLessThanOrEqual(0.5);
          if (at) expect(Math.abs(geometry[at]!.top - geometry[at - 1]!.top - 22)).toBeLessThanOrEqual(0.5);
        }
        await steps.getByRole("button", { name: "Find the retry handler" }).click();
        // An opened call is its arguments as labeled fields and its output (ToolDetail), never one JSON block.
        expect(await steps.locator(".cv-tool-detail__key").allTextContents()).toContain("pattern");
        expect(await steps.textContent()).not.toContain('"pattern"');
        if (!working) {
          // Closed, the capture's screenshot is the small image at its row's edge.
          const edge = steps.getByRole("img", { name: "Capture the repaired screen" });
          await edge.waitFor();
          await steps.locator("button.cv-tool", { hasText: "Capture the repaired screen" }).click();
          // Opened, the row shows its image under it (ToolImages) and the small one steps aside, so a
          // run of captures stays a list of lines (Lucas, 2026-11-11).
          const shot = steps.locator(".cv-tool-images img").first();
          await shot.waitFor();
          await shot.evaluate((image) => (image as HTMLImageElement).decode());
          expect(await shot.evaluate((image) => (image as HTMLImageElement).naturalWidth)).toBeGreaterThan(0);
          expect(await edge.count()).toBe(0);
        }
        expect(await steps.textContent()).not.toContain("Loaded tools");
        expect(await steps.textContent()).not.toContain("Waiting…");
      } finally {
        await page.close();
      }
    });

  test("the script gallery uses natural word spacing and aligns Raw with the tool icon column", async () => {
    const page = await browser.newPage({ viewport: { width: 640, height: 820 }, deviceScaleFactor: 2 });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}/test/browser/tool-row-column.html?fixture=script`);
      await page.locator(".cv-cmux-exec__raw button").waitFor();
      await page.evaluate(() => document.fonts.ready);
      const m = await page.evaluate(() => {
        const row = document.querySelector(".cv-tool")!;
        const words = row.querySelector(".cv-tool__text")!;
        const wordBox = (word: string) => {
          const walker = document.createTreeWalker(words, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const at = node.textContent!.indexOf(word);
            if (at < 0) continue;
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + word.length);
            return range.getBoundingClientRect();
          }
          throw new Error(`Missing word: ${word}`);
        };
        const raw = document.querySelector(".cv-cmux-exec__raw button")!;
        const icon = raw.querySelector(".cv-tool__icon");
        return {
          gap: wordBox("workspaces").left - wordBox("Listed").right,
          iconOffset: icon
            ? icon.getBoundingClientRect().left - row.querySelector(".cv-tool__icon")!.getBoundingClientRect().left
            : null,
        };
      });
      expect(m.gap).toBeGreaterThan(0);
      expect(m.gap).toBeLessThan(8);
      expect(m.iconOffset).not.toBeNull();
      expect(Math.abs(m.iconOffset!)).toBeLessThanOrEqual(0.5);
      await page.locator(".cv-cmux-exec__raw button").click();
      expect(await page.locator(".cv-cmux-exec__raw .cv-mcp-call__name").textContent()).toContain("cmux_exec");
    } finally {
      await page.close();
    }
  });
});
