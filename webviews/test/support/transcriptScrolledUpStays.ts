// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolled up, the reader stays where they are until they ask for the latest row (Leo, 2026-11-07:
// "if I'm in the middle of your prompt, should I get automatically sent down? ... if I was reading
// something else, like why would I want to push down? Like I can just click the jump to bottom
// button if I want.").
//
// Following comes back only on an explicit action (Jump to latest, a send, End) or the reader's own
// downward scroll that reaches the end. The transcript used to take any scroll down to within its
// 4 px deadband of the end as the reader's while any input of the last second was held: a press on
// text, a sideways wheel, a wheel an inner scroller took, an up key, or a pointer move after a press
// whose release never came. A layout change that moved the view down there in that second turned
// following back on, and the reply streaming next carried the reader to the bottom.
//
// Each case parks the reader up a streaming reply, gives one of those inputs, then moves the view
// down to 2 px over its end the way a layout change does (a write to the offset, no reader input).
// The reply then streams on: following stays off and the offset stays where it was. The explicit
// ways back (a wheel down to the end, End, Jump to latest, a send) still follow the reply.
//
// A wheel down over a tool's output that is already at its end moves the transcript (the browser
// passes it on), and is the reader's own scroll down; one over an output with room left, or one that
// contains its overscroll, moves the transcript not at all. Find's search field keeps End and
// Cmd-Down for its caret.
//
// Real Chromium and WebKit from Playwright; CI fails the file when an engine cannot launch.
//
// Why parts: one file for all 42 cases took about 150 s and CI's runner kills a file at 120 s, so
// each engine x case group is its own file (transcript-scrolled-up-stays-{chromium,webkit}-
// {stays,back}-browser.test.ts), one engine and one Vite server each.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserContext, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

type Probe = Window & {
  __showRowsSync(rows: unknown[]): void;
  __send(): void;
  __followSnapshot(): { following: boolean; arms: { path: string; input: string | null }[] };
  __stream(): void;
};

export type ScrolledUpStaysPart = {
  /** The part's test file name, for requireBrowserLane. */
  file: string;
  engine: "chromium" | "webkit";
  /**
   * "stays": the inputs that are not the reader scrolling down, then a layout change to the end, and
   * Find's End keys.
   * "back": the explicit ways back, and the wheels over a tool's output.
   */
  cases: "stays" | "back";
  /** vite.config.ts, named in the part's own file so the runner sees a dev server file. */
  configFile: string;
};

const engineTypes: Record<ScrolledUpStaysPart["engine"], BrowserType> = { chromium, webkit };

export async function scrolledUpStays({ file, engine, cases, configFile }: ScrolledUpStaysPart): Promise<void> {
  await requireBrowserLane(file, async () => {
    setDefaultTimeout(240_000);
    const engines: [string, BrowserType][] = [];
    if (await probeEngineOrSkip(file, engine, engineTypes[engine])) engines.push([engine, engineTypes[engine]]);
    if (engines.length === 0) return;
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "../..");
    let vite: Awaited<ReturnType<typeof createServer>> | undefined;
    const browsers = new Map<string, Browser>();
    // One context per engine: its pages share the HTTP cache, so each case's page does not fetch
    // the agent pane's modules from Vite again. Each case still gets its own page.
    const contexts = new Map<string, BrowserContext>();
    beforeAll(async () => {
      vite = await createServer({
        root: webviews,
        configFile,
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
        plugins: [
          {
            // The pane's Jump to latest, which the harness leaves off.
            name: "jump-button",
            enforce: "pre",
            transform(code, id) {
              if (id.endsWith("/test/browser/transcript-follow.harness.tsx"))
                return code.replace(
                  "<VirtualTranscript",
                  "<VirtualTranscript jumpButton find={(window as unknown as { __find?: never }).__find}",
                );
            },
          },
        ],
      });
      await vite.listen();
      await warmViteServer(vite, "/test/browser/transcript-follow.html");
      for (const [name, engine] of engines) {
        const browser = await engine.launch({ headless: true });
        browsers.set(name, browser);
        contexts.set(name, await browser.newContext({ viewport: { width: 900, height: 600 } }));
      }
    });
    afterAll(async () => {
      for (const browser of browsers.values()) await browser.close();
      await vite?.close();
    });

    const frames = (page: Page, count = 4) =>
      page.evaluate(async (n) => {
        for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
      }, count);
    const view = (page: Page) =>
      page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const { following, arms } = (window as unknown as Probe).__followSnapshot();
        return {
          top: node.scrollTop,
          fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop,
          following,
          arms,
        };
      });

    /// A chat with a reply streaming, the reader parked `distance` px up it with a real wheel, and
    /// the wheel's input hold over (so only the case's own input is held).
    async function parked(name: string, distance: number, setup?: (page: Page) => Promise<unknown>) {
      const page = await contexts.get(name)!.newPage();
      await installPaintedFrames(page);
      await setup?.(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRowsSync" in window);
      await page.evaluate(() => {
        const w = window as unknown as Probe;
        const history = Array.from({ length: 30 }, (_, i) => ({
          id: `history-${i}`,
          kind: i % 2 ? "assistant" : "user",
          text:
            i % 2 ? `Answer ${i}. ${"The keeper wiped the salt from the lantern glass. ".repeat(3)}` : `Question ${i}?`,
          version: 1,
          at: 1,
        }));
        let text = "A streaming reply. ".repeat(60);
        let version = 1;
        w.__stream = () => {
          text += `\n\nAnother streamed paragraph ${version}. ${"More words arrive. ".repeat(5)}`;
          version += 1;
          w.__showRowsSync([...history, { id: "stream", kind: "assistant", text, streaming: true, version, at: 1 }]);
        };
        w.__stream();
      });
      await frames(page, 10);
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, -distance);
      // The wheel's own input hold (userScroll.ts USER_SCROLL_INTENT_MS) lapses: each case holds only its own input.
      // fixed-wait: the one-second input hold is the behavior under test.
      await page.waitForTimeout(1_150);
      await frames(page);
      const start = await view(page);
      expect(start.following, `${name}: parked ${distance}px up`).toBe(false);
      return { page, box };
    }

    /// Resolves once the view is at rest: no finite animation running (a glide, a fold), and three
    /// painted frames in a row with the same offset and height.
    const settled = (page: Page) =>
      page.evaluate(
        () =>
          new Promise<void>((done) => {
            let last = "";
            let alike = 0;
            const deadline = performance.now() + 5_000;
            window.cmuxAfterPaint(() => {
              const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const moving = node
                .getAnimations({ subtree: true })
                .some((each) => each.playState === "running" && each.effect?.getTiming().iterations !== Infinity);
              const now = `${Math.round(node.scrollTop)} ${node.scrollHeight}`;
              alike = !moving && now === last ? alike + 1 : 0;
              last = now;
              if (alike >= 3 || performance.now() > deadline) {
                done();
                return false;
              }
            });
          }),
      );
    /// A layout change moves the view down to 2 px over its end: a write to the offset, no input.
    const layoutScrollToEnd = (page: Page) =>
      page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        node.scrollTop = node.scrollHeight - node.clientHeight - 2;
      });
    const streamOn = async (page: Page, chunks = 6) => {
      for (let chunk = 0; chunk < chunks; chunk++) {
        await page.evaluate(() => (window as unknown as Probe).__stream());
        await frames(page, 3);
      }
    };
    /// A history row's text in view, away from any control.
    async function textInView(page: Page) {
      return page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const box = node.getBoundingClientRect();
        const row = [...node.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="history-"] p')].find((each) => {
          const rect = each.getBoundingClientRect();
          return rect.top > box.top + 20 && rect.bottom < box.top + box.height / 2;
        })!;
        const rect = row.getBoundingClientRect();
        return { x: rect.left + 12, y: rect.top + rect.height / 2 };
      });
    }

    /// Inputs that are not the reader scrolling down, each held for a second by the scroll intent.
    const notDown: Record<
      string,
      (page: Page, box: { x: number; y: number; width: number; height: number }) => Promise<void>
    > = {
      "a press on text": async (page) => {
        const at = await textInView(page);
        await page.mouse.click(at.x, at.y);
      },
      "a sideways wheel": async (page, box) => {
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
        await page.mouse.wheel(60, 0);
      },
      "a wheel an inner scroller takes": async (page) => {
        const at = await page.evaluate(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const box = node.getBoundingClientRect();
          const row = [...node.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="history-"]')].find(
            (each) => each.getBoundingClientRect().top > box.top + 20,
          )!;
          const inner = document.createElement("div");
          inner.id = "inner-scroller";
          inner.style.cssText = "height:60px;overflow:auto";
          inner.innerHTML = '<div style="height:600px">output</div>';
          row.append(inner);
          const rect = inner.getBoundingClientRect();
          return { x: rect.left + 20, y: rect.top + 30 };
        });
        await page.mouse.move(at.x, at.y);
        await page.mouse.wheel(0, 40);
        await frames(page);
        expect(await page.evaluate(() => document.getElementById("inner-scroller")!.scrollTop)).toBeGreaterThan(0);
      },
      "an up key": async (page) => {
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await page.keyboard.press("ArrowUp");
      },
      "a pointer move after a press whose release never came": async (page) => {
        const at = await textInView(page);
        await page.evaluate(({ x, y }) => {
          const target = document.elementFromPoint(x, y)!;
          target.dispatchEvent(
            new PointerEvent("pointerdown", {
              bubbles: true,
              composed: true,
              clientX: x,
              clientY: y,
              buttons: 1,
              isPrimary: true,
            }),
          );
        }, at);
        // Hovering on: the first move reports no button down, and the press counts as released.
        await page.mouse.move(at.x + 40, at.y + 10, { steps: 3 });
      },
    };

    if (cases === "stays")
      for (const [name] of engines)
        for (const [input, give] of Object.entries(notDown))
          for (const distance of [30, 90])
            test(`${name}: ${input}, then a layout change to the end ${distance}px up, keeps the reader's place`, async () => {
              // fixed-wait: parked() lets the wheel's one-second input hold lapse.
              const { page, box } = await parked(name, distance);
              await give(page, box);
              await layoutScrollToEnd(page);
              await frames(page, 6);
              const landed = await view(page);
              await streamOn(page);
              const after = await view(page);
              await page.close();
              expect({ following: after.following, moved: after.top - landed.top, arms: after.arms }).toEqual({
                following: false,
                moved: 0,
                arms: [],
              });
              // The reply grew below the reader, out of view.
              expect(after.fromEnd).toBeGreaterThan(40);
            });

    /// The explicit ways back to the latest row: each follows the reply that streams on.
    const backToLatest: Record<
      string,
      (page: Page, box: { x: number; y: number; width: number; height: number }) => Promise<string>
    > = {
      "a wheel down to the end": async (page, box) => {
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.wheel(0, 4000);
        return "reader-scroll";
      },
      "End, the page focused": async (page) => {
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await page.keyboard.press("End");
        return "end-key";
      },
      "Cmd-Down on a row": async (page) => {
        const at = await textInView(page);
        await page.mouse.click(at.x, at.y);
        await page.keyboard.press("Meta+ArrowDown");
        return "end-key";
      },
      "End on a row": async (page) => {
        // A row the reader picked takes the keys (the transcript's roving tab stop); End goes to the last.
        const at = await textInView(page);
        await page.mouse.click(at.x, at.y);
        await page.keyboard.press("End");
        return "end-key";
      },
      "Jump to latest": async (page) => {
        await page.locator(".acpmux-jump-latest:not(.acpmux-jump-up)[data-shown]").click();
        return "jump";
      },
      "a send": async (page) => {
        await page.evaluate(() => (window as unknown as Probe).__send());
        return "send";
      },
    };
    if (cases === "back")
      for (const [name] of engines)
        for (const [action, take] of Object.entries(backToLatest))
          test(`${name}: ${action} goes back to the latest row and follows it`, async () => {
            // fixed-wait: parked() lets the wheel's one-second input hold lapse.
            const { page, box } = await parked(name, 200);
            const path = await take(page, box);
            await settled(page);
            await streamOn(page);
            // Following waits out the reader's own input hold (followDeferred) before it settles at the end.
            await page
              .waitForFunction(
                () => {
                  const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
                  return node.scrollHeight - node.clientHeight - node.scrollTop <= 4;
                },
                undefined,
                { timeout: 4_000 },
              )
              .catch(() => {});
            await settled(page);
            const after = await view(page);
            await page.close();
            expect(after.following).toBe(true);
            expect(after.fromEnd).toBeLessThanOrEqual(4);
            // followTrace names what brought following back.
            expect(after.arms.at(-1)?.path).toBe(path);
          });

    /// A tool's output in a row in view: `room` px it can still scroll down, and its overscroll rule.
    async function output(page: Page, room: number, overscroll = "auto") {
      return page.evaluate(
        ({ room, overscroll }) => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const box = node.getBoundingClientRect();
          const row = [...node.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="history-"]')].find(
            (each) => each.getBoundingClientRect().top > box.top + 20,
          )!;
          const inner = document.createElement("pre");
          inner.id = "tool-output";
          inner.style.cssText = `height:80px;overflow:auto;margin:0;overscroll-behavior:${overscroll}`;
          inner.textContent = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n");
          row.append(inner);
          inner.scrollTop = inner.scrollHeight - inner.clientHeight - room;
          const rect = inner.getBoundingClientRect();
          return { x: rect.left + 40, y: rect.top + 40 };
        },
        { room, overscroll },
      );
    }
    const innerTop = (page: Page) => page.evaluate(() => document.getElementById("tool-output")!.scrollTop);

    if (cases === "back")
      for (const [name] of engines)
        test(`${name}: a wheel down over an output at its end, to the transcript's end, follows the reply again`, async () => {
          // fixed-wait: parked() lets the wheel's one-second input hold lapse.
          const { page } = await parked(name, 200);
          const at = await output(page, 0);
          const before = await innerTop(page);
          await page.mouse.move(at.x, at.y);
          await page.mouse.wheel(0, 4000);
          await settled(page);
          await streamOn(page);
          await page
            .waitForFunction(
              () => {
                const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
                return node.scrollHeight - node.clientHeight - node.scrollTop <= 4;
              },
              undefined,
              { timeout: 4_000 },
            )
            .catch(() => {});
          await settled(page);
          const after = await view(page);
          const inner = await innerTop(page);
          await page.close();
          expect(inner).toBe(before);
          expect(after.following).toBe(true);
          expect(after.fromEnd).toBeLessThanOrEqual(4);
          expect(after.arms.at(-1)).toMatchObject({ path: "reader-scroll" });
          expect(after.arms.at(-1)?.input).toStartWith("wheel ");
        });

    if (cases === "back")
      for (const [name] of engines)
        for (const [kind, room, overscroll] of [
          ["with room left", 300, "auto"],
          ["at its end that contains its overscroll", 0, "contain"],
        ] as const)
          test(`${name}: a wheel down over an output ${kind} moves only the output, and following stays off`, async () => {
            // fixed-wait: parked() lets the wheel's one-second input hold lapse.
            const { page } = await parked(name, 90);
            const start = await view(page);
            const at = await output(page, room, overscroll);
            const before = await innerTop(page);
            await page.mouse.move(at.x, at.y);
            await page.mouse.wheel(0, 40);
            await settled(page);
            const wheeled = await view(page);
            // Then a layout change lands at the transcript's end inside the wheel's input hold.
            await layoutScrollToEnd(page);
            await frames(page, 6);
            const landed = await view(page);
            await streamOn(page);
            const after = await view(page);
            const inner = await innerTop(page);
            await page.close();
            expect(wheeled.top).toBe(start.top);
            if (room > 0) expect(inner).toBeGreaterThan(before);
            expect({ following: after.following, moved: after.top - landed.top, arms: after.arms }).toEqual({
              following: false,
              moved: 0,
              arms: [],
            });
          });

    if (cases === "stays")
      for (const [name] of engines)
        for (const key of ["End", "Meta+ArrowDown"])
          test(`${name}: ${key} in Find's search field moves its caret, not the transcript`, async () => {
            // Find open over the chat, as Cmd-F leaves it: its search field focused.
            // fixed-wait: parked() lets the wheel's one-second input hold lapse.
            const { page: chat } = await parked(name, 200, (each) =>
              each.addInitScript(() => {
                const noop = () => {};
                (window as unknown as { __find: unknown }).__find = {
                  open: true,
                  query: "the keeper wiped the salt",
                  matches: [],
                  active: 0,
                  show: noop,
                  hide: noop,
                  setQuery: noop,
                  next: noop,
                  previous: noop,
                  focusRequest: 1,
                };
              }),
            );
            const field = chat.locator(".acpmux-find input");
            await field.focus();
            await field.evaluate((input: HTMLInputElement) => input.setSelectionRange(0, 0));
            const start = await view(chat);
            await chat.evaluate(() => {
              (window as unknown as { __prevented?: boolean }).__prevented = false;
              document.addEventListener("keydown", (event) => {
                if (event.defaultPrevented) (window as unknown as { __prevented?: boolean }).__prevented = true;
              });
            });
            await chat.keyboard.press(key);
            await settled(chat);
            await streamOn(chat);
            const after = await view(chat);
            const caret = await field.evaluate((input: HTMLInputElement) => ({
              at: input.selectionStart,
              length: input.value.length,
              focused: document.activeElement === input,
            }));
            const prevented = await chat.evaluate(() => (window as unknown as { __prevented?: boolean }).__prevented);
            await chat.close();
            expect({ prevented, focused: caret.focused }).toEqual({ prevented: false, focused: true });
            if (key === "End") expect(caret.at).toBe(caret.length);
            expect({ following: after.following, arms: after.arms }).toEqual({ following: false, arms: [] });
            // The transcript never goes to its end. Playwright's WebKit takes Linux's key bindings, where
            // Meta+ArrowDown in a one-line field is no caret move and the engine scrolls the page a line
            // itself (not the pane's code: nothing prevented the key, nothing re-armed); on macOS it moves
            // the caret to the end, as End does.
            if (key === "End" || name !== "webkit") expect(after.top - start.top).toBe(0);
            else expect(after.fromEnd).toBeGreaterThan(40);
          });
  });
}
