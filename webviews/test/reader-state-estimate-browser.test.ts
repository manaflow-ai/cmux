// l10n-allow-file: test fixture prompts, commands and messages, not shipped UI.
// Leo, 2026-11-17: a big empty band under an expanded group, and rows shifting while scrolling. The
// transcript places a row it has not measured yet at its estimate (model.ts `fallbackRowHeight`), and
// base estimated a line the reader opened at its closed height: a long prompt over Show more, a
// thought, a command's Shell card, a sent message, and the edited-files card whatever the reader left
// it. Here each is drawn in the real transcript, shut and then opened by the reader's click, and the
// estimate the transcript itself computes for it (its `layoutConversation`, imported into the page,
// reading the same open-state stores) is within the 4 px spacing token of the height it draws.
// readerStateEstimates.test.tsx holds the same cases in jsdom; this file holds them to the drawn page.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("reader-state-estimate-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `reader-state-estimate-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("reader state estimates", () => test("no engine", () => {}));
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
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
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
  const shell = (id: string, command: string, output: string, exitCode = 0): Item => ({
    kind: "tool",
    text: command,
    tool: { id, title: command, kind: "execute", status: "completed", command, output, exitCode },
  });
  const edit = (id: string, file: string, newText: string): Item => ({
    kind: "tool",
    text: `Edit ${file}`,
    tool: {
      id,
      title: `Edit ${file}`,
      kind: "edit",
      status: "completed",
      locations: [{ path: file }],
      diffs: [{ path: file, oldText: "export const a = 1;\n", newText }],
    },
  });
  const lines = (count: number, line: (n: number) => string) =>
    Array.from({ length: count }, (_, n) => line(n + 1)).join("\n");
  const send =
    "acpmux send lane-a 'The retry guard is fixed and the suite passes on main. Please rebase your branch onto it and rerun the integration tests before you merge.'";

  /// Each case: its row, and how the reader leaves it open (a click on its first shut line, or a setting).
  const cases: { name: string; row: Row; open: "click" | "collapse-then-click"; all?: true }[] = [
    {
      name: "long prompt (40 lines)",
      row: row(
        "prompt",
        "user",
        lines(40, (n) => `Line ${n} of the long prompt about the retry helper.`),
      ),
      open: "click",
    },
    {
      name: "thought",
      row: step("thought", [
        {
          kind: "thought",
          text:
            "Looking at the retry helper. The guard runs after the total, so the second pass lets a value past the ceiling. " +
            "I should check where the policy is read, then move the guard before the sum and run the tests again to see the failure go away.",
          startedAt: 1,
          endedAt: 1,
        },
      ]),
      open: "click",
    },
    {
      name: "shell, 30 lines out",
      row: step("tests", [
        shell(
          "cmd-1",
          "bun test src/retry",
          lines(30, (n) => `✓ case ${n} keeps the cache stable`),
        ),
      ]),
      open: "click",
    },
    {
      name: "shell, 1,000 lines out",
      row: step("long-out", [
        shell(
          "cmd-2",
          "bun test",
          lines(1_000, (n) => `✓ case ${n} keeps the cache stable`),
        ),
      ]),
      open: "click",
      // Past 400 lines its end shows, with Show all under the box (ShellBlock.tsx `OutputMore`).
      all: true,
    },
    {
      name: "shell, exit 1",
      row: step("lint", [
        shell(
          "cmd-3",
          "bun run lint",
          "src/retry.ts:4 unused import\nsrc/retry.ts:9 missing return type\n2 problems",
          1,
        ),
      ]),
      open: "click",
    },
    {
      name: "sent message",
      row: step("sent", [{ ...shell("send-1", send, "queued"), text: send }]),
      open: "click",
    },
    {
      name: "edited-files card",
      row: row("edits", "activity", undefined, {
        ended: true,
        merged: ["edits"],
        items: [
          edit("e1", "/home/dev/cmux/src/retry.ts", "export const a = 2;\nexport const b = 3;\n"),
          edit("e2", "/home/dev/cmux/src/policy.ts", "export const a = 2;\nexport const b = 3;\n"),
        ],
      }),
      open: "collapse-then-click",
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
  /// The row's box once its height has held for 6 painted frames (a fold plays first).
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
  const setEditedFiles = (page: Page, show: string | undefined) =>
    page.evaluate(async (value) => {
      const settings = (await import(
        /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/turnChanges/settings.ts`
      )) as typeof import("../src/agent-session/acpmux/turnChanges/settings");
      settings.setEditedFilesSettings(value ? { show: value as never } : {});
    }, show);

  for (const [name] of engines) {
    test(`${name}: each line the reader opens is estimated at the height it draws, shut and open`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1100, height: 800 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showSession" in window);
      const misses: string[] = [];
      for (const [index, { name: kind, row: shown, open, all }] of cases.entries()) {
        const session = `reader-state-${index}`;
        await page.evaluate(
          ([id, list]) =>
            (window as unknown as { __showSession(id: string, rows: unknown): void }).__showSession(id, list),
          [session, [row(`${shown.id}-ask`, "user", "Go on."), shown]] as const,
        );
        const states: [string, () => Promise<void>][] = [["shut", async () => {}]];
        const line = page.locator(`.acpmux-row[data-row-id="${shown.id}"] [aria-expanded="false"]`).first();
        if (open === "collapse-then-click") {
          // Shown always is the default (agentPane.editedFiles.show); collapsed, the reader opens it.
          states[0]![0] = "shown always";
          states.push(["collapsed", () => setEditedFiles(page, "collapsed")]);
        }
        states.push(["opened", () => line.click()]);
        if (all)
          states.push([
            "Show all",
            () => page.locator(`.acpmux-row[data-row-id="${shown.id}"] .cv-output-more`).click(),
          ]);
        for (const [state, act] of states) {
          await act();
          const drawn = await settled(page, shown.id);
          const estimated = await estimate(page, shown, drawn.width, session);
          console.log(`reader-state ${name} ${kind} ${state}: estimated ${estimated} px, drawn ${drawn.height} px`);
          if (Math.abs(estimated - drawn.height) > 4)
            misses.push(`${kind} ${state}: estimated ${estimated}, drawn ${drawn.height}`);
        }
        if (open === "collapse-then-click") await setEditedFiles(page, undefined);
      }
      expect(misses).toEqual([]);
      await page.close();
    });
  }
});
