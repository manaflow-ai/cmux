// l10n-allow-file: test fixture paths and code, not shipped UI.
// Leo, 2026-11-17: a big empty band under an expanded group, and rows shifting while scrolling. An
// edits group in a finished run ("Edited 2 files") starts closed; opened, it draws each changed file's
// diff card under its line (ToolGroupRow.tsx, EditDiff.tsx). The transcript places a row it has not
// measured yet at its estimate (model.ts `foldedGroupHeight`), which kept an opened edits group at its
// closed line (22 px), so wherever the drawn height was gone (windowing, paging, another width) the rows
// under it were placed a diff or more too high and moved when it mounted. Here each group is drawn in
// the real transcript, shut and then opened by the reader's click, and the transcript's own estimate
// for the row (its `layoutConversation`, imported into the page, reading the same disclosure store) is
// within the 4 px spacing token of the height it draws.
//
// The card draws at the chat's text size and the Interface Size (its head at `--cv-font-size`, its rows
// at the code's line height, conversation.css `.cv-edit-diff*`), so each group is checked at the default
// look, at a larger chat text size (Settings > Agent Chat > Text Size, `agentPane.display.font.size`) and
// at a larger Interface Size (the host's scale script: `--cmux-interface-scale` and the chat's text scale
// `--cmux-chat-text-scale`, then `cmux-ui-scale-change`).
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Chromium keeps its scrollbars (Playwright's headless default hides them, which no engine the chat runs in
// does), so an unwrapped card's sideways scrollbar takes its lane as it does in the app.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("edits-group-estimate-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const launchOptions = (name: string) =>
    name === "chromium" ? { headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] } : { headless: true };
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch(launchOptions(engine[0]))).close();
      engines.push(engine);
    } catch {
      console.warn(
        `edits-group-estimate-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("edits group estimates", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch(launchOptions(name)));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  type Item = Record<string, unknown>;
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  /// A finished step inside an opened "Worked for", as turns.ts shapes it.
  const step = (id: string, items: Item[]) => row(id, "activity", undefined, { settled: true, foldRun: true, items });
  const edit = (id: string, file: string, oldText: string, newText: string): Item => ({
    kind: "tool",
    text: `Edit ${file}`,
    tool: {
      id,
      title: `Edit ${file}`,
      kind: "edit",
      status: "completed",
      locations: [{ path: file }],
      diffs: [{ path: file, oldText, newText }],
    },
  });
  /// An edit that carried no diff (a delete): listed as its row in the opened group.
  const removal = (id: string, file: string): Item => ({
    kind: "tool",
    text: `Delete ${file}`,
    tool: { id, title: `Delete ${file}`, kind: "delete", status: "completed", locations: [{ path: file }] },
  });
  const lines = (count: number, line: (n: number) => string) =>
    Array.from({ length: count }, (_, n) => `${line(n + 1)}\n`).join("");
  const source = lines(60, (n) => `export const value${n} = ${n};`);
  const changed = source
    .replace("export const value5 = 5;", "export const value5 = 50;")
    .replace("export const value40 = 40;", "export const value40 = 400;");

  const cases: { name: string; row: Row }[] = [
    {
      name: "two small edits",
      row: step("two", [
        edit(
          "e1",
          "/home/dev/cmux/src/retry.ts",
          "export const a = 1;\n",
          "export const a = 2;\nexport const b = 3;\n",
        ),
        edit("e2", "/home/dev/cmux/src/policy.ts", "export const c = 1;\n", "export const c = 2;\n"),
      ]),
    },
    {
      name: "one long edit (cut to eight lines)",
      row: step("long", [
        edit(
          "e3",
          "/home/dev/cmux/src/table.ts",
          "",
          lines(30, (n) => `export const row${n} = "${n}";`),
        ),
      ]),
    },
    {
      name: "two hunks in one file",
      row: step("hunks", [edit("e4", "/home/dev/cmux/src/values.ts", source, changed)]),
    },
    {
      // One hunk 30 lines into the file: Pierre's separator over it, eight rows, not cut.
      name: "one change deep in a file",
      row: step("deep", [
        edit(
          "e7",
          "/home/dev/cmux/src/values.ts",
          source,
          source.replace("export const value30 = 30;", "export const value30 = 3;"),
        ),
      ]),
    },
    {
      // A prose file wraps its rows (blockWrap.ts): its long lines take two or three rows.
      name: "a Markdown file",
      row: step("prose", [
        edit(
          "e8",
          "/home/dev/cmux/docs/retry.md",
          "# Retry\n",
          "# Retry\n\nThe retry helper runs the guard before the total, so a second pass can never let a value past the ceiling the policy sets for the request, whatever the backoff.\n",
        ),
      ]),
    },
    {
      name: "an edit and a delete",
      row: step("mixed", [
        edit("e5", "/home/dev/cmux/src/retry.ts", "export const a = 1;\n", "export const a = 2;\n"),
        removal("e6", "/home/dev/cmux/src/old.ts"),
      ]),
    },
  ];

  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  const box = (page: Page, id: string) =>
    page.evaluate((rowId) => {
      const node = document.querySelector<HTMLElement>(`.acpmux-scroll .acpmux-row[data-row-id="${rowId}"]`);
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { height: rect.height, width: rect.width };
    }, id);
  /// The row's box once its height has held for 6 painted frames (a fold and the diff's renderer play first).
  const settled = async (page: Page, id: string) => {
    let last = -1;
    for (let held = 0, frames = 0; held < 6 && frames < 240; frames += 1) {
      await painted(page);
      const height = (await box(page, id))?.height ?? -1;
      held = Math.abs(height - last) < 0.01 ? held + 1 : 0;
      last = height;
    }
    return (await box(page, id))!;
  };
  /// The transcript's own estimate for the row in this chat, at the width it lays rows out at.
  const estimate = (page: Page, shown: Row, width: number, session: string) =>
    page.evaluate(
      async ([one, w, id]) => {
        const model = (await import(
          /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/model.ts`
        )) as typeof import("../src/agent-session/acpmux/model");
        return model.layoutConversation([one as never], w, undefined, undefined, undefined, undefined, id).heights[0]!;
      },
      [shown, width, session] as const,
    );

  /// The looks each group is checked at: the default, a larger chat text, a larger Interface Size.
  const sizes: { name: string; apply: (page: Page) => Promise<void> }[] = [
    { name: "default size", apply: async () => {} },
    {
      name: "chat text 18px",
      apply: (page) =>
        page.evaluate(async () => {
          const { setChatDisplay } = (await import(
            /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/chatDisplay.ts`
          )) as typeof import("../src/agent-session/acpmux/chatDisplay");
          setChatDisplay({ "agentPane.display.font.size": 18 });
        }),
    },
    {
      name: "interface size 1.25",
      apply: (page) =>
        page.evaluate(() => {
          const root = document.documentElement.style;
          root.setProperty("--cmux-interface-scale", "1.25");
          root.setProperty("--cmux-chat-text-scale", "1.25");
          window.dispatchEvent(new Event("cmux-ui-scale-change"));
        }),
    },
  ];

  for (const [name] of engines) {
    for (const size of sizes) {
      test(`${name}, ${size.name}: an edits group the reader opens is estimated at the height it draws, shut and open`, async () => {
        const page = await browsers.get(name)!.newPage({ viewport: { width: 1100, height: 800 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
        await page.waitForFunction(() => "__showSession" in window);
        // The estimate this checks is behind Settings > Advanced > Experiments > Expanded Edits Estimate.
        await page.evaluate(async () => {
          const { setExperimentSwitches } = (await import(
            /* @vite-ignore */ `${location.origin}/src/experiments/switches.ts`
          )) as typeof import("../src/experiments/switches");
          setExperimentSwitches({ expandedEditsEstimate: true });
        });
        await size.apply(page);
        await painted(page, 2);
        const misses: string[] = [];
        for (const [index, { name: kind, row: shown }] of cases.entries()) {
          const session = `edits-group-${index}`;
          await page.evaluate(
            ([id, list]) =>
              (window as unknown as { __showSession(id: string, rows: unknown): void }).__showSession(id, list),
            [session, [row(`${shown.id}-ask`, "user", "Go on."), shown]] as const,
          );
          const line = page.locator(`.acpmux-row[data-row-id="${shown.id}"] button[data-tool-group][aria-expanded]`);
          const states: [string, () => Promise<void>][] = [
            ["shut", async () => expect(await line.getAttribute("aria-expanded")).toBe("false")],
            ["opened", () => line.click()],
          ];
          for (const [state, act] of states) {
            await act();
            const drawn = await settled(page, shown.id);
            const estimated = await estimate(page, shown, drawn.width, session);
            console.log(
              `edits-group ${name} ${size.name} ${kind} ${state}: estimated ${estimated} px, drawn ${drawn.height} px, error ${(estimated - drawn.height).toFixed(2)} px`,
            );
            if (Math.abs(estimated - drawn.height) > 4)
              misses.push(`${kind} ${state}: estimated ${estimated}, drawn ${drawn.height}`);
          }
        }
        expect(misses).toEqual([]);
        await page.close();
      });
    }
  }
});
