// l10n-allow-file: synthetic agent names, tool titles and messages for a geometry test.
// Every one-line activity row in the transcript (a tool row, a sent message, another agent's
// received line, an inbox notice line, a background task's line, a report batch's head and the
// waiting messages' head) is one line of the same height, the same distance from the next one,
// with its icon in one column and its words in one column (Leo, 2026-11-01, on a column of tool,
// inbox, message and fold rows: "doesn't make sense for these to be spaced differently"). Real
// layout: the transcript as the agent pane draws it (VirtualTranscript, test/browser/transcript-follow.html).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { batchLaneNotices } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";
import { PENDING_MESSAGES_ROW_ID, pendingMessagesRow } from "../src/agent-session/acpmux/conversation/pendingMessages";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-row-pitch-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
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
    await warmViteServer(vite, "/test/browser/transcript-follow.html", { timeoutMs: 200_000 });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const call = (id: string, title: string, kind: string, extra: Record<string, unknown> = {}) =>
    row(id, "activity", undefined, {
      items: [{ kind: "tool", text: title, tool: { id: `${id}-call`, title, kind, status: "completed", ...extra } }],
    } as Partial<AcpmuxRow>);
  const incoming = (id: string, text: string, provenance: Record<string, unknown>, extra: Partial<AcpmuxRow> = {}) =>
    row(id, "user", text, {
      untyped: true,
      incoming: incomingPrompt(text, { _meta: { provenance } }) as AcpmuxRow["incoming"],
      ...extra,
    });
  const fromSession = (id: string, name: string, text: string, extra: Partial<AcpmuxRow> = {}) =>
    incoming(
      id,
      text,
      { kind: "session_message", from: `acp:${name}`, fromShortName: name, fromHarness: "claude" },
      extra,
    );
  const inbox = (id: string, sender: string, pr: number) =>
    incoming(id, `[inbox] New messages from other agents in 1 thread.\n- 1 new in #${pr} from ${sender}: Ready.`, {
      kind: "inbox_notice",
      threads: [
        {
          threadId: `from:${sender}/pr:${pr}`,
          label: `#${pr}`,
          new: 1,
          from: [sender],
          promptIds: [`${id}-prompt`],
          preview: "Ready for review.",
        },
      ],
    });
  const sha = "0123456789abcdef0123456789abcdef01234567";
  const report = (id: string, verdict: string) =>
    row(id, "user", `Review (Astra): ${verdict} at ${sha}`, {
      untyped: true,
      incoming: {
        kind: "message",
        message: {
          name: "review-lane",
          text: `Review (Astra): ${verdict} at ${sha}`,
          raw: `Review (Astra): ${verdict} at ${sha}`,
          report: true,
        },
      },
    } as Partial<AcpmuxRow>);
  const waiting = fromSession("waiting", "fs-lane-3", "One more thing when you are free.", {
    steer: "waiting",
    steerPromptId: "waiting-prompt",
  });
  const rows: AcpmuxRow[] = [
    row("u0", "user", "Land the transcript fixes"),
    row("a0", "assistant", "Working through the lanes now."),
    fromSession("m1", "gcp-a-lane", "The batch is next."),
    call("t1", "Ran 4 commands", "execute"),
    inbox("i1", "fs-lane-1", 101),
    call("t2", "Read App.tsx", "read", { locations: [{ path: "/repo/App.tsx" }] }),
    ...batchLaneNotices([report("r1", "SHIP"), report("r2", "BLOCK")]),
    call("t3", "Start Gallery", "execute"),
    row("n1", "user", "Background build finished", {
      untyped: true,
      incoming: { kind: "notice", text: "Background build finished" },
    }),
    call("t4", "SendMessage", "other", {
      inputSummary: JSON.stringify({ to: "gcp-a-lane", message: "Rebase on base, then land." }),
    }),
    inbox("i2", "fs-lane-2", 102),
    call("t5", "Check status", "execute"),
    fromSession("m2", "gcp-a-lane", "Landed."),
    pendingMessagesRow([waiting], [])!,
  ];

  for (const theme of ["dark", "light"] as const)
    test(`${theme}: one-line activity rows share one pitch, one icon column and one text column`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 1400 }, deviceScaleFactor: 2 });
      try {
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.emulateMedia({ colorScheme: theme });
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
        await page.waitForFunction(() => "__showRawRows" in window);
        await page.evaluate(
          (shown) => (window as unknown as { __showRawRows(rows: unknown): void }).__showRawRows(shown),
          rows,
        );
        await page.locator(".cv-pending__line").waitFor();
        await page.evaluate(() => document.fonts.ready);
        // Two frames for the transcript to place rows by their drawn heights.
        await page.evaluate(
          () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 300)))),
        );
        const lines = await page.evaluate(() => {
          // A one-line row's line, and where its icon is drawn inside it.
          const LINE = [
            ".acpmux-row > .cv-tools > .cv-tool",
            ".acpmux-row > .cv-tools > * > .cv-tool",
            ".acpmux-row > .cv-tools .cv-agent-activity-row",
            ".cv-received > .cv-disclosure__line",
            ".cv-lane-batch .cv-agent-activity-row",
            ".cv-pending__line",
          ].join(", ");
          const ICON = ".cv-tool__icon, .cv-agentmsg__icon, .cv-received__mark, .cv-pending__icon";
          /// The left of the first glyph drawn under `el` outside its icon.
          const textLeft = (el: Element, icon: Element | null) => {
            const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              if (!node.textContent?.trim() || icon?.contains(node)) continue;
              const range = document.createRange();
              const start = node.textContent.search(/\S/);
              range.setStart(node, start);
              range.setEnd(node, start + 1);
              const box = range.getBoundingClientRect();
              if (box.width > 0) return box.left;
            }
            return Number.NaN;
          };
          const found = [...document.querySelectorAll(LINE)].filter(
            (el, _index, all) => !all.some((other) => other !== el && other.contains(el)),
          );
          return found.map((el) => {
            const box = el.getBoundingClientRect();
            const icon = el.querySelector(ICON);
            const article = el.closest<HTMLElement>(".acpmux-row");
            // How far the line's own parts (its buttons, its sentence) stand out of its box.
            const overhang = Math.max(
              0,
              ...[...el.children].map((child) => {
                const part = child.getBoundingClientRect();
                return part.height === 0 ? 0 : Math.max(box.top - part.top, part.bottom - box.bottom);
              }),
            );
            return {
              row: article?.dataset.rowId ?? "?",
              line: el.className.toString().split(" ")[0],
              top: box.top,
              height: box.height,
              overhang,
              icon: icon?.getBoundingClientRect().left ?? Number.NaN,
              text: textLeft(el, icon),
            };
          });
        });
        console.log(`ROW_PITCH ${JSON.stringify({ theme, lines })}`);
        expect(errors).toEqual([]);
        expect(lines.map((line) => line.row)).toEqual([
          "m1",
          "t1",
          "i1",
          "t2",
          "lane-notices:r1",
          "t3",
          "n1",
          "t4",
          "i2",
          "t5",
          "m2",
          PENDING_MESSAGES_ROW_ID,
        ]);
        const [first] = lines;
        const pitch = lines[1]!.top - first!.top;
        const off = lines.flatMap((line, index) => {
          const name = `${line.row} (${line.line})`;
          const previous = lines[index - 1];
          return [
            ...(Math.abs(line.height - first!.height) > 0.5
              ? [`${name} is ${line.height}px tall, ${first!.row} ${first!.height}px`]
              : []),
            ...(line.overhang > 0.5 ? [`${name} has a part ${line.overhang}px out of its line`] : []),
            ...(previous && Math.abs(line.top - previous.top - pitch) > 0.5
              ? [`${name} sits ${line.top - previous.top}px under ${previous.row}, ${pitch}px elsewhere`]
              : []),
            ...(Math.abs(line.icon - first!.icon) > 0.5
              ? [`${name} icon at ${line.icon}, ${first!.icon} elsewhere`]
              : []),
            ...(Math.abs(line.text - first!.text) > 0.5
              ? [`${name} words at ${line.text}, ${first!.text} elsewhere`]
              : []),
          ];
        });
        expect(off).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
