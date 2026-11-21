// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// A sent message's row (SentMessageLine.tsx) never runs past its pane (cmux#37879 review): in the
// batch gallery's opened group, "Sent to acpmux-owner · ci-box" and its "Read at its next step"
// drew past the transcript's right edge at a narrow pane, as the status kept its room and the
// recipient did not give way. The received line it matches cuts its sender and preview first and
// keeps its chevron and actions in sight; the sent line does the same.
//
// At narrow and normal pane widths, in light and dark, in real Chromium on the gallery frame: each
// sent row's status and chevron end inside the row and the pane, the status reads whole, and
// nothing scrolls sideways. CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("sent-row-narrow-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.acpmux-batch-send";
  const HEIGHT = 640;
  const WIDTHS = [320, 400, 480, 760];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE } : {}),
    });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "batches" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("a sent row at a narrow pane", () => {
    for (const colorScheme of ["light", "dark"] as const)
      for (const width of WIDTHS)
        test(`${colorScheme} at ${width}px: status and chevron inside the row and the pane`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(ENTRY, { variant: "batches", colorScheme, width, height: HEIGHT }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
            // The play opened the group: its rows are drawn (its own layout judgement is the gallery's).
            await page.locator(".cv-sent-msg").first().waitFor();
            await page.evaluate(async () => {
              await document.fonts.ready;
              await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
            });

            const rows = await page.evaluate(() =>
              [...document.querySelectorAll<HTMLElement>(".cv-sent-msg")].map((row) => {
                const line = row.querySelector<HTMLElement>(":scope > .cv-agentmsg__line")!;
                const status = line.querySelector<HTMLElement>(".cv-sent__status");
                const words = status?.querySelector<HTMLElement>(".cv-row-status");
                const chevron = line.querySelector<Element>(".cv-agentmsg__chevron > .cv-rotor")!;
                const scroller = row.closest<HTMLElement>(".cv-scroll, [data-transcript-scroller]") ?? document.body;
                const right = (el: Element | null | undefined) => (el ? el.getBoundingClientRect().right : 0);
                return {
                  text: line.textContent ?? "",
                  line: right(line),
                  row: right(row),
                  pane: Math.min(window.innerWidth, scroller.getBoundingClientRect().right),
                  status: status ? right(status) : undefined,
                  statusCut: words ? words.scrollWidth > words.clientWidth + 0.5 : false,
                  chevron: right(chevron),
                  chevronLeft: chevron.getBoundingClientRect().left,
                  statusLeft: status ? status.getBoundingClientRect().left : undefined,
                  // The sender's parts (the words, the chip, the machine) end before the chevron.
                  sender: Math.max(
                    0,
                    ...[...line.querySelectorAll<HTMLElement>(".cv-received__sender > *")].map((part) => right(part)),
                  ),
                  lineOverflows: line.scrollWidth > line.clientWidth + 0.5,
                };
              }),
            );
            // The batch the review named is drawn: acpmux-owner, read at its next step.
            const owner = rows.find((row) => row.text.includes("acpmux-owner"));
            expect(owner).toBeDefined();
            expect(owner!.status).toBeDefined();
            for (const row of rows) {
              const edge = Math.min(row.line, row.row, row.pane) + 0.5;
              expect({ text: row.text, chevron: row.chevron <= edge }).toEqual({ text: row.text, chevron: true });
              // Nothing lies over another: the recipient gives way before the chevron, the chevron
              // before the status.
              // An empty toggle takes back the line's gap before the chevron by design
              // (AgentMessageRow.css "transcript-chevron-after-label"): 4px is that pull, not overlap.
              expect({ text: row.text, sender: row.sender <= row.chevronLeft + 4 }).toEqual({
                text: row.text,
                sender: true,
              });
              if (row.statusLeft !== undefined)
                expect({ text: row.text, chevron: row.chevron <= row.statusLeft + 0.5 }).toEqual({
                  text: row.text,
                  chevron: true,
                });
              if (row.status !== undefined)
                expect({ text: row.text, status: row.status <= edge, cut: row.statusCut }).toEqual({
                  text: row.text,
                  status: true,
                  cut: false,
                });
              expect({ text: row.text, overflow: row.lineOverflows }).toEqual({ text: row.text, overflow: false });
            }
            const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
            expect(scrollWidth).toBe(width);
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
