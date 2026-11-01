// l10n-allow-file: public transcript fixtures, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { GAP_KINDS, gapPair } from "../src/agent-session/acpmux/conversation/selectionGaps.fixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("transcript-gap-select-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      plugins: [
        {
          name: "transcript-shadow-highlight-fixture",
          enforce: "pre",
          resolveId(source, importer) {
            if (source === "./highlightPool" && importer?.includes("/acpmux/conversation/"))
              return path.join(root, "test/browser/transcript-shadow-highlight.fixture.ts");
          },
        },
      ],
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const) {
      browsers.set(name, await engine.launch({ headless: true }));
    }
    if (process.env.CMUX_GAP_CAPTURE)
      await warmGalleryFrame(vite, "agent-pane.gutter-select", {
        browser: browsers.get("chromium"),
        params: { variant: "gaps-ready" },
      });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });
  const paint = (page: Page) =>
    page.evaluate(async () => {
      for (let left = 4; left > 0; left--) await window.cmuxPaintFrame();
    });
  const selected = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");
  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move(to.x, to.y, { steps: 6 });
    await paint(page);
    await page.mouse.up();
  };
  const open = async (
    name: string,
    above: (typeof GAP_KINDS)[number],
    below: (typeof GAP_KINDS)[number],
    fixture?: { rows: ReturnType<typeof gapPair>; css: string; dir: string },
  ) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 900 }, reducedMotion: "reduce" });
    await installPaintedFrames(page);
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRawRows" in window);
    if (fixture) {
      await page.addStyleTag({ content: fixture.css });
      await page.evaluate((dir) => (document.documentElement.dir = dir), fixture.dir);
    }
    await page.evaluate(
      (rows) => (window as unknown as { __showRawRows(rows: unknown): void }).__showRawRows(rows),
      fixture?.rows ?? gapPair(above, below),
    );
    await page.waitForSelector('[data-row-id="after"]');
    for (const id of ["upper", "lower"]) {
      const toggle = page.locator(`[data-row-id="${id}"] .cv-tool.is-toggle`);
      if (await toggle.count()) await toggle.click();
    }
    await paint(page);
    return page;
  };
  const geometry = (page: Page) =>
    page.evaluate(() => {
      const textBox = (id: string) => {
        const row = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.startsWith(`${id} keeper`)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rects = Array.from(range.getClientRects());
          if (!rects.length) continue;
          const first = rects[0]!,
            last = rects[rects.length - 1]!;
          return {
            top: first.top,
            bottom: last.bottom,
            x: first.left + 30,
            y: first.top + first.height / 2,
          };
        }
        throw new Error(`No visible text for ${id}`);
      };
      const upper = textBox("upper"),
        lower = textBox("lower"),
        after = textBox("after");
      const column = document.querySelector<HTMLElement>('[data-row-id="upper"]')!.getBoundingClientRect();
      const upperRow = document.querySelector<HTMLElement>('[data-row-id="upper"]')!;
      const padding = Number.parseFloat(getComputedStyle(upperRow).paddingBottom);
      return {
        upper,
        lower,
        after,
        upperRowBottom: column.bottom,
        lowerRowTop: document.querySelector('[data-row-id="lower"]')!.getBoundingClientRect().top,
        // Tool headers are controls before their output. Aim at the row's real blank trailing
        // padding, so the midpoint cannot accidentally be inside the next tool's disclosure.
        gapY: column.bottom - Math.max(1, padding / 2),
        hasRowPadding: padding > 0,
        center: (column.left + column.right) / 2,
        left: column.left / 2,
        right: (column.right + innerWidth - 16) / 2,
      };
    });
  for (const name of ["chromium", "webkit"]) {
    for (const lineDirection of ["rtl", "ltr"] as const)
      test(`${name}: RTL document gaps and both gutters preserve ${lineDirection} line endpoints`, async () => {
        const text =
          lineDirection === "rtl"
            ? { upper: "אבגדה וזחטי כלמנס", lower: "עפצקר שתאבג דהוזח", after: "טיכלמ נסעפצ קרשתא" }
            : { upper: "Upper keeper", lower: "Lower harbour", after: "After the watch" };
        // Mount the actual fixture content and spacing together, so virtual row positions include
        // the padding. Its empty band extends beyond the reply footer to test both nearest lines.
        const page = await open(name, "agent", "agent", {
          rows: gapPair("agent", "agent").map((row) => ({
            ...row,
            text: text[row.id as keyof typeof text] ?? row.text,
          })),
          dir: "rtl",
          // RTL inherits the document; a local LTR line must keep its own endpoints.
          // Specific enough to win over a reply's kept room (conversation.css `.acpmux-row--reply-room`).
          css:
            'article.acpmux-row.acpmux-row[data-row-id="upper"] { padding-bottom: 64px; }' +
            (lineDirection === "ltr" ? ".cv-md p { direction: ltr; }" : ""),
        });
        try {
          const box = await page.evaluate(() => {
            const line = (id: string) => {
              const paragraph = document.querySelector<HTMLElement>(`[data-row-id="${id}"] .cv-md p`)!;
              const range = document.createRange();
              range.selectNodeContents(paragraph);
              const rect = range.getBoundingClientRect();
              return {
                top: rect.top,
                bottom: rect.bottom,
                left: rect.left,
                right: rect.right,
                text: paragraph.textContent!,
                direction: getComputedStyle(paragraph).direction,
              };
            };
            const column = document.querySelector('[data-row-id="upper"]')!.getBoundingClientRect();
            const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
            return {
              upper: line("upper"),
              lower: line("lower"),
              after: line("after"),
              gap: (() => {
                const rect = document
                  .querySelector('[data-row-id="upper"] [data-transcript-gap="row"]')!
                  .getBoundingClientRect();
                return { top: rect.top, bottom: rect.bottom };
              })(),
              xs: [
                (view.left + column.left) / 2,
                (column.left + column.right) / 2,
                (column.right + view.right - 16) / 2,
              ],
            };
          });
          expect(box.upper.direction).toBe(lineDirection);
          expect(box.lower.direction).toBe(lineDirection);
          expect(box.lower.top - box.upper.bottom).toBeGreaterThan(4);
          expect(box.gap.bottom - box.gap.top).toBe(64);
          expect(box.gap.bottom).toBeLessThanOrEqual(box.lower.top);
          expect(box.gap.top - box.upper.bottom).toBeLessThan(box.lower.top - box.gap.top);
          expect(box.lower.top - box.gap.bottom).toBeLessThan(box.gap.bottom - box.upper.bottom);
          const end = {
            x: lineDirection === "rtl" ? box.after.left + 0.5 : box.after.right - 0.5,
            y: (box.after.top + box.after.bottom) / 2,
          };
          for (const [row, y, offset] of [
            ["upper", box.gap.top + 1, box.upper.text.length],
            ["lower", box.gap.bottom - 1, 0],
          ] as const)
            for (const x of box.xs) {
              await drag(page, { x, y }, end);
              const selection = await page.evaluate(() => {
                const value = getSelection()!;
                return {
                  row: value.anchorNode?.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id"),
                  offset: value.anchorOffset,
                  text: value.toString(),
                };
              });
              const from = `${row} ${lineDirection} at ${x},${y}`;
              expect(selection.row, from).toBe(row);
              expect(selection.offset, from).toBe(offset);
              expect(selection.text, from).toContain(box.lower.text);
              expect(selection.text, from).not.toContain(box.upper.text);
            }
        } finally {
          await page.close();
        }
      });
    for (const above of GAP_KINDS)
      for (const below of GAP_KINDS) {
        test(`${name}: ${above} to ${below} gap and side gutters restart at the nearest caret`, async () => {
          const page = await open(name, above, below);
          const box = await geometry(page);
          expect(box.lower.top).toBeGreaterThan(box.upper.bottom);
          const nearestRow = box.gapY - box.upper.bottom <= box.lower.top - box.gapY ? "upper" : "lower";
          // Consecutive tool rows can have zero row padding: their content owns the center.
          for (const x of [...(box.hasRowPadding ? [box.center] : []), box.left, box.right]) {
            await drag(page, { x, y: box.gapY }, box.after);
            expect((await selected(page)).length).toBeGreaterThan(0);
            const anchor = await page.evaluate(() => {
              const s = getSelection()!;
              return {
                row: s.anchorNode?.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id"),
                offset: s.anchorOffset,
                length: s.anchorNode?.textContent?.length,
              };
            });
            expect(anchor.row).toBe(nearestRow);
            expect(anchor.offset).toBe(nearestRow === "upper" ? (anchor.length ?? -1) : 0);
            // Restart from an existing selection, then a plain gap click must clear it.
            await drag(page, { x, y: box.gapY }, box.lower);
            expect((await selected(page)).length).toBeGreaterThan(0);
            await page.mouse.click(x, box.gapY);
            expect(await selected(page)).toBe("");
          }
          await page.close();
        });
        test(`${name}: ${above} to ${below} inter-row midpoint starts at the nearest caret`, async () => {
          const page = await open(name, above, below);
          // Integration-fixture spacing only: leave real row renderers and controls intact while
          // adding a positive gap outside both article boxes without replacing fractional placement.
          await page.evaluate(() => {
            for (const id of ["lower", "after"]) {
              const row = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
              row.style.marginTop = `${(Number.parseFloat(row.style.marginTop) || 0) + 32}px`;
            }
          });
          await paint(page);
          const box = await geometry(page);
          expect(box.lowerRowTop - box.upperRowBottom).toBeGreaterThanOrEqual(32);
          const midpoint = (box.upperRowBottom + box.lowerRowTop) / 2;
          expect(midpoint).toBeGreaterThan(box.upperRowBottom);
          expect(midpoint).toBeLessThan(box.lowerRowTop);
          const nearestRow = midpoint - box.upper.bottom <= box.lower.top - midpoint ? "upper" : "lower";
          for (const x of [box.center, box.left, box.right]) {
            // The press belongs to empty transcript space, never to a tool disclosure or another
            // row control. Those surfaces keep their ownership in the existing control regression.
            expect(
              await page.evaluate(
                ({ x, y }) => {
                  const target = document.elementFromPoint(x, y);
                  return Boolean(
                    target?.closest(".acpmux-thread, .acpmux-spacer, .acpmux-scroll") && !target.closest(".acpmux-row"),
                  );
                },
                { x, y: midpoint },
              ),
            ).toBe(true);
            await drag(page, { x, y: midpoint }, box.after);
            expect((await selected(page)).length).toBeGreaterThan(0);
            const anchor = await page.evaluate(() => {
              const selection = getSelection()!;
              return {
                row: selection.anchorNode?.parentElement?.closest(".acpmux-row")?.getAttribute("data-row-id"),
                offset: selection.anchorOffset,
                length: selection.anchorNode?.textContent?.length,
              };
            });
            expect(anchor.row).toBe(nearestRow);
            expect(anchor.offset).toBe(nearestRow === "upper" ? (anchor.length ?? -1) : 0);
            await drag(page, { x, y: midpoint }, box.lower);
            expect((await selected(page)).length).toBeGreaterThan(0);
            await page.mouse.click(x, midpoint);
            expect(await selected(page)).toBe("");
          }
          await page.close();
        });
      }
    for (const [kind, label] of [
      ["highlighted-code", "HighlightedCode"],
      ["edit-diff-hunks", "EditDiffHunks"],
    ] as const)
      test(`${name}: ${label} shadow text keeps native selection ownership`, async () => {
        const page = await open(name, "agent", "agent");
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(String(error)));
        try {
          await page.evaluate((surface) => {
            const mount = (
              window as unknown as {
                __mountShadowSurface(rowId: string, kind: "highlighted-code" | "edit-diff-hunks"): Promise<void>;
              }
            ).__mountShadowSurface("upper", surface);
            return mount;
          }, kind);
          const surfaceSelector = `#shadow-surface-${kind}`;
          const textSelector = `${surfaceSelector} diffs-container`;
          try {
            await page.waitForFunction((surface) => {
              const host = document.querySelector<HTMLElement>(surface);
              return Array.from(host?.shadowRoot?.querySelectorAll("[data-line]") ?? []).some((line) =>
                line.textContent?.includes("shadow code"),
              );
            }, textSelector);
          } catch (error) {
            console.error(
              `SHADOW_READINESS ${name} ${kind}`,
              await page.evaluate((surface) => {
                const mount = document.querySelector(surface);
                const host = mount?.querySelector("diffs-container");
                return {
                  markup: mount?.outerHTML.slice(0, 2500),
                  shadow: host?.shadowRoot?.innerHTML.slice(0, 2500),
                  lines: Array.from(host?.shadowRoot?.querySelectorAll("[data-line]") ?? []).map(
                    (line) => line.textContent,
                  ),
                  worker: document.documentElement.dataset.shadowHighlightWorker,
                };
              }, surfaceSelector),
              errors,
            );
            throw error;
          }
          await paint(page);
          console.log(
            `SHADOW_HOST_READY ${name} ${label}`,
            await page.evaluate((surface) => {
              const host = document.querySelector(surface)!;
              return {
                tag: host.localName,
                className: host.className,
                lines: Array.from(host.shadowRoot!.querySelectorAll("[data-line]")).map((line) => line.textContent),
              };
            }, textSelector),
          );
          const point = await page.evaluate((surface) => {
            const host = document.querySelector<HTMLElement>(surface);
            const line = Array.from(host?.shadowRoot?.querySelectorAll<HTMLElement>("[data-line]") ?? []).find(
              (candidate) => candidate.textContent?.includes("shadow code"),
            );
            if (!line) throw new Error(`No shadow text for ${surface}`);
            const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
            const rects: DOMRect[] = [];
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              const range = document.createRange();
              range.selectNodeContents(node);
              rects.push(...Array.from(range.getClientRects()).filter((rect) => rect.width > 0));
            }
            const rect = rects[0];
            if (!rect) throw new Error(`No painted shadow text for ${surface}`);
            const end = rects.at(-1)!;
            return {
              from: { x: rect.left + Math.min(4, rect.width / 2), y: rect.top + rect.height / 2 },
              to: { x: Math.max(end.left + 1, end.right - 2), y: end.top + end.height / 2 },
            };
          }, textSelector);
          await drag(page, point.from, point.to);
          const details = await page.evaluate((surface) => {
            const selection = getSelection()!;
            return {
              text: selection.toString(),
              prevented: document.querySelector<HTMLElement>(surface)?.dataset.shadowPrevented,
            };
          }, surfaceSelector);
          expect(details.prevented).toBe("false");
          expect(details.text).toContain("shadow code");
          expect(details.text).not.toContain("upper keeper checks");
          expect(details.text).not.toContain("lower keeper checks");
        } finally {
          await page.evaluate(() =>
            (window as unknown as { __unmountShadowSurfaces(): void }).__unmountShadowSurfaces(),
          );
          const remaining = await page.locator('[id^="shadow-surface-"]').count();
          await page.close();
          expect(remaining).toBe(0);
        }
      });
    test(`${name}: control presses, control drags, and text presses retain native ownership`, async () => {
      const page = await open(name, "tool", "prompt");
      await page.evaluate(() => {
        const row = document.querySelector('[data-row-id="upper"]')!;
        const wrap = document.createElement("div");
        wrap.id = "selection-controls";
        wrap.style.cssText = "position:relative;z-index:2;padding:8px";
        wrap.innerHTML =
          '<button>Attach file</button><a href="#fixture">Harbour link</a><span role="button" tabindex="0">Sender chip</span><input aria-label="Fixture field"><span draggable="true">Drag file</span><span data-interactive><span id="custom-control">Custom control</span></span><div class="acpmux-edited-title--toggle" data-interactive>Open file diff</div><div class="acpmux-turn-preview-frame" data-interactive style="height:30px">Open preview</div>';
        row.querySelector(".cv-tools")!.append(wrap);
        wrap.addEventListener("pointerdown", (event) => (wrap.dataset.prevented = String(event.defaultPrevented)));
        const hidden = document.createElement("span");
        hidden.className = "cv-code-handoff__real";
        hidden.textContent = "Invisible duplicate that must never become a selection anchor";
        hidden.style.cssText = "opacity:0;pointer-events:none;position:absolute";
        row.append(hidden);
      });
      await paint(page);
      const end = (await geometry(page)).after;
      for (const selector of [
        "button",
        "a",
        '[role="button"]',
        "input",
        '[draggable="true"]',
        "#custom-control",
        ".acpmux-edited-title--toggle",
        ".acpmux-turn-preview-frame",
      ]) {
        const control = page.locator(`#selection-controls ${selector}`);
        const box = (await control.boundingBox())!;
        await drag(page, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, end);
        expect(await page.locator("#selection-controls").getAttribute("data-prevented")).toBe("false");
      }
      const toggle = page.locator('[data-row-id="upper"] .cv-tool.is-toggle');
      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("false");
      await paint(page);
      await page.evaluate(() => {
        document.querySelector('[data-row-id="lower"] .cv-user__text')!.addEventListener("pointerdown", (event) => {
          document.body.dataset.textPrevented = String(event.defaultPrevented);
        });
      });
      const textPoints = await page.evaluate(() => {
        const point = (selector: string) => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector(selector)!);
          const rect = Array.from(range.getClientRects()).find((box) => box.width > 0 && box.height > 0)!;
          return { x: rect.left + 30, y: rect.top + rect.height / 2 };
        };
        return {
          prompt: point('[data-row-id="lower"] .cv-user__text'),
          after: point('[data-row-id="after"] .cv-md'),
        };
      });
      await drag(page, textPoints.prompt, textPoints.after);
      expect(await page.locator("body").getAttribute("data-text-prevented")).toBe("false");
      expect((await selected(page)).length).toBeGreaterThan(0);
      expect(await selected(page)).not.toContain("Invisible duplicate");
      await page.close();
    });
    test(`${name}: padding inside content remains owned by that content`, async () => {
      const page = await open(name, "agent", "agent");
      await page.evaluate(() => {
        const text = document.querySelector('[data-row-id="upper"] .cv-md')!;
        text.innerHTML =
          '<div class="cv-code-handoff is-plain" style="padding-bottom:40px"><pre class="cv-code-plain selectable"><span id="visible-gap-code">upper keeper visible code</span></pre><div class="cv-code-handoff__real" style="top:20px"><pre class="selectable">Invisible duplicate code</pre></div></div>';
        text.addEventListener("pointerdown", (event) => {
          document.body.dataset.contentPrevented = String(event.defaultPrevented);
        });
      });
      await paint(page);
      const point = await page.evaluate(() => {
        const visible = document.getElementById("visible-gap-code")!;
        const rect = visible.getBoundingClientRect();
        const row = visible.closest(".acpmux-row")!.getBoundingClientRect();
        return { x: (row.left + row.right) / 2, y: rect.bottom + 12 };
      });
      const after = await page.locator('[data-row-id="after"] .cv-md').boundingBox();
      await drag(page, point, { x: after!.x + 90, y: after!.y + 8 });
      expect(await page.locator("body").getAttribute("data-content-prevented")).toBe("false");
      await page.close();
    });
    test(`${name}: ReplyMedia native play and seek presses never start transcript selection`, async () => {
      const page = await open(name, "agent", "agent");
      try {
        await page.evaluate(() =>
          (window as unknown as { __mountReplyMedia(rowId: string): Promise<void> }).__mountReplyMedia("upper"),
        );
        const media = page.locator("#gap-reply-media");
        const video = media.locator("video");
        await video.waitFor();
        await media.locator(".cv-media__poster").click();
        await page.waitForFunction(() => document.querySelector<HTMLVideoElement>("#gap-reply-media video")?.controls);
        await paint(page);
        await page.evaluate(() => getSelection()?.removeAllRanges());
        const box = (await video.boundingBox())!;
        // Real browser input on the native play and seek strips. Their shadow UI retargets to
        // <video>; neither the strips nor the video body are transcript padding.
        const points = [
          { x: box.x + 18, y: box.y + box.height - 16 },
          { x: box.x + box.width / 2, y: box.y + box.height - 36 },
          { x: box.x + box.width / 2, y: box.y + box.height / 2 },
        ];
        for (const point of points) {
          await page.mouse.click(point.x, point.y);
          await paint(page);
          expect(await selected(page)).toBe("");
        }
      } finally {
        await page.evaluate(() =>
          (window as unknown as { __unmountReplyMedia(): Promise<void> }).__unmountReplyMedia(),
        );
        await page.close();
      }
    });
  }
  if (process.env.CMUX_GAP_CAPTURE)
    test("public gallery before/after capture", async () => {
      const label = process.env.CMUX_GAP_CAPTURE!;
      const page = await browsers
        .get("chromium")!
        .newPage({ viewport: { width: 1280, height: 560 }, reducedMotion: "reduce" });
      await installPaintedFrames(page);
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.gutter-select", { variant: "gaps-ready", width: 1280, height: 560, frame: "component", theme: "Apple System Colors", locale: "en" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await paint(page);
      const box = await geometry(page);
      await drag(page, { x: box.center, y: box.gapY }, box.after);
      const hasSelection = (await selected(page)).length > 0;
      expect(hasSelection).toBe(label === "after");
      console.log(
        `GAP_GALLERY_CAPTURE_${label}=${(await page.locator(".acpmux-shell").screenshot()).toString("base64")}`,
      );
      console.log(
        `GAP_GALLERY_META=${JSON.stringify({ label, selection: hasSelection, viewport: "1280x560", theme: "Apple System Colors", locale: "en", engine: `Chromium ${browsers.get("chromium")!.version()}`, fixture: "agent-pane.gutter-select/gaps-ready" })}`,
      );
      await page.close();
    });
});
