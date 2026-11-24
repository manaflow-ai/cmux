// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The tagged-ask card (agent-pane.next-step-card, NextStepCard.tsx) in real Chromium on the gallery
// frame, light and dark: every look draws its question and one button per answer, the shipped box's
// buttons sit on one line at the normal width with the first carrying its ⌘↩ keycap, nothing draws
// past the frame's right edge, and an answered card has no buttons. With FAST_CHECKS_OUT set, each
// state's card is saved there at 2x for the PR. CI fails the file when Chromium cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("next-step-card-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.next-step-card";
  const PANE_ENTRY = "agent-pane.next-step-in-pane";
  const HEIGHT = 280;
  const WIDTH = 640;
  const VARIANTS: Record<string, { buttons: number }> = {
    "box-choices": { buttons: 3 },
    "box-yes-no": { buttons: 2 },
    "box-answered": { buttons: 0 },
    "box-answered-typed": { buttons: 0 },
    "recap-choices": { buttons: 3 },
    "inline-choices": { buttons: 3 },
    "consent-choices": { buttons: 3 },
    "list-choices": { buttons: 3 },
  };
  const out = process.env.FAST_CHECKS_OUT;
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "box-choices" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("tagged-ask card looks", () => {
    for (const [variant, { buttons }] of Object.entries(VARIANTS))
      for (const scheme of ["dark", "light"] as const)
        test(`${variant} (${scheme})`, async () => {
          const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 2 });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(ENTRY, { variant, width: WIDTH, height: HEIGHT, colorScheme: scheme }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            const card = page.locator(".acpmux-next-step").first();
            await card.waitFor();
            const layout = await page.evaluate(() => {
              const card = document.querySelector(".acpmux-next-step")!;
              const answers = [...card.querySelectorAll(".acpmux-next-step__answer")].map((el) =>
                el.getBoundingClientRect(),
              );
              return {
                text: card.textContent ?? "",
                buttons: answers.length,
                lines: new Set(answers.map((box) => Math.round(box.top))).size,
                numbered: card.querySelector(".acpmux-next-step__answer.is-primary .acpmux-question-number") !== null,
                right: card.getBoundingClientRect().right,
                width: document.documentElement.clientWidth,
              };
            });
            expect(layout.buttons).toBe(buttons);
            expect(layout.text).toMatch(/\?/);
            expect(layout.right).toBeLessThanOrEqual(layout.width);
            // The answers are the question card's numbered rows (2026-11-24): one row each.
            if (buttons > 0) expect(layout.numbered).toBe(true);
            if (variant.startsWith("box-") && buttons > 0) expect(layout.lines).toBe(buttons);
            if (out)
              await page
                .locator(".acpmux-next-step-gallery")
                .screenshot({ path: path.join(out, `${variant}-${scheme}.png`) });
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });

  // The transcript places the reply under a card by its first estimate (cardHeight.ts
  // nextStepCardHeight) until the card draws: the card must draw exactly that tall, in a pane that can
  // send and in each that cannot (Lucas, 2026-11-24: the same card read only), with a recap, a cut
  // question and Show more, a wrapped answer, answered and superseded. The gallery frame writes both.
  const HOLDS = [
    "box-choices",
    "box-watching",
    "box-subagent",
    "box-disconnected",
    "box-remote",
    "box-origin",
    "box-guest",
    "box-wrapping",
    "box-wrapping-watching",
    "box-long",
    "box-long-watching",
    "wrap-up-recap",
    "wrap-up-recap-watching",
    "wrap-up-recap-answered",
    "wrap-up-recap-only",
    "box-answered",
    "box-answered-typed",
    "box-superseded",
    "box-no-answers",
    "box-no-answers-watching",
  ];
  describe("the first estimate is the drawn height", () => {
    for (const variant of HOLDS)
      for (const width of [420, 640])
        test(`${variant} at ${width}`, async () => {
          const height = variant.startsWith("box-long") ? 560 : HEIGHT;
          const page = await browser!.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(ENTRY, { variant, width, height, colorScheme: "dark" }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            await page.waitForFunction(() => document.querySelector<HTMLElement>("[data-drawn]") !== null);
            const read = await page.evaluate(() => {
              const frame = document.querySelector<HTMLElement>("[data-drawn]")!;
              return {
                estimate: Number(frame.dataset.estimate),
                drawn: Number(frame.dataset.drawn),
                // Show more is the reader's own, in every pane.
                controls: frame.querySelectorAll(
                  ".acpmux-next-step button:not(.acpmux-next-step__more), .acpmux-next-step input",
                ).length,
                reason: frame.querySelector(".acpmux-next-step__reason")?.textContent ?? "",
              };
            });
            expect(Math.abs(read.drawn - read.estimate)).toBeLessThan(1);
            // A card that cannot send has nothing to press or type, and says why.
            if (/watching|subagent|disconnected|remote|origin|guest/.test(variant) && !variant.includes("no-answers")) {
              expect(read.controls).toBe(0);
              expect(read.reason).not.toBe("");
            }
          } finally {
            await page.close();
          }
        });
  });

  // The real pane on a snapshot: the transcript's own shaping places the card (turns.ts NEXT_STEP).
  describe("in the agent pane", () => {
    for (const [variant, cards] of [
      ["waiting", 1],
      ["waiting-view-only", 1],
      ["answered", 1],
      ["ordinary-question", 0],
    ] as const)
      for (const scheme of ["dark", "light"] as const)
        test(`${variant} (${scheme})`, async () => {
          const page = await browser!.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(PANE_ENTRY, { variant, width: 760, height: 560, colorScheme: scheme }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            if (cards) await page.locator(".acpmux-next-step").first().waitFor();
            expect(await page.locator(".acpmux-next-step").count()).toBe(cards);
            if (variant === "answered") expect(await page.locator(".acpmux-next-step__answer").count()).toBe(0);
            // View Only reaches the card through the pane (subagents/restart.ts answerBlock): its
            // answers read as a list, nothing to press or type, and the reason in the last row.
            if (variant === "waiting-view-only") {
              expect(await page.locator("li.acpmux-next-step__answer").count()).toBe(3);
              expect(await page.locator(".acpmux-next-step button, .acpmux-next-step input").count()).toBe(0);
              expect(await page.locator(".acpmux-next-step__reason").textContent()).toBe("Take over to answer");
            }
            if (out) await page.screenshot({ path: path.join(out, `pane-${variant}-${scheme}.png`) });
          } finally {
            await page.close();
          }
        });
  });

  // The click path, headless: the box from a real chat's call_log (a wrap-up called from a
  // cmux_exec script), a click on an answer, and that answer sent as the next prompt, a reply
  // quoting the ask, which its bubble draws as a quote.
  test("a wrap-up answer click sends the answer as a reply quoting the ask", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
    try {
      const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
      await page.goto(
        base + galleryFrame(PANE_ENTRY, { variant: "wrap-up-click", width: 760, height: 560, colorScheme: "dark" }),
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      const card = page.locator(".acpmux-next-step").first();
      await card.waitFor({ timeout: 20_000 }).catch(async (error: unknown) => {
        const seen = await page.evaluate(() => ({
          attach: (window as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] }).cmuxGalleryLog
            .filter((entry) => entry.method.includes("attach") || entry.method.includes("session/load"))
            .map((entry) => JSON.stringify(entry.params)),
          text: document.body.innerText.slice(0, 1200),
        }));
        throw new Error(`no next-step box; attach ${seen.attach.join(" | ")}; page: ${seen.text}`, { cause: error });
      });
      expect(await card.textContent()).toContain("Checked the folder: it is empty.");
      expect(await card.locator(".acpmux-next-step__answer .acpmux-next-step__label").allTextContents()).toEqual([
        expect.stringContaining("Yes, add README"),
        "No thanks",
      ]);
      if (out) await page.screenshot({ path: path.join(out, "pane-wrap-up-code-mode-dark.png") });
      await card.locator(".acpmux-next-step__answer", { hasText: "Yes, add README" }).click();
      // The pane's send path on its acpmux link: the in-page mock logs each request it answers.
      const sent = await page
        .waitForFunction(
          () => {
            type Entry = { method: string; params?: { prompt?: unknown } };
            const log = (window as unknown as { cmuxGalleryLog: Entry[] }).cmuxGalleryLog;
            for (const entry of log) {
              if (entry.method === "acpmux session/prompt" && Array.isArray(entry.params?.prompt))
                return (entry.params.prompt as { text?: string }[]).map((block) => block.text ?? "").join("");
            }
            return undefined;
          },
          undefined,
          { timeout: 30_000 },
        )
        .catch(async (error: unknown) => {
          const calls = await page.evaluate(() =>
            (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.map((entry) => entry.method),
          );
          throw new Error(`no prompt was sent; the frame's calls: ${calls.join(", ")}`, { cause: error });
        });
      // The answer goes as a reply to the ask (nextStepAsk.ts `answerPrompt`): the ask quoted under
      // who asked, then the answer. Leo, 2026-11-08, on a bare "Not now" bubble: "wait this thing
      // should've shown that it was a reply to an ask from you".
      const quote = "Claude Code: Should I add a README here?";
      expect(await sent.jsonValue()).toBe(`> ${quote}\n\nYes, add README`);
      // Its bubble draws the quote as every quoted reply does (the muted bar), the answer under it.
      const bubble = page.locator(".cv-user__body", { has: page.locator(".cv-quote") }).last();
      await bubble.waitFor({ timeout: 30_000 });
      expect((await bubble.locator(".cv-quote").textContent())?.trim()).toBe(quote);
      expect(await bubble.textContent()).toContain("Yes, add README");
      expect(await bubble.textContent()).not.toContain(">");
      // The row's first-layout estimate (model.ts `layoutConversation`) is its drawn height, so
      // nothing under the reply moves when it mounts. A plain prompt is measured the same way.
      const fits = await page.evaluate(
        async (texts) => {
          const model = "/gallery/src/agent-session/acpmux/model.ts";
          const { layoutConversation } = (await import(
            /* @vite-ignore */ model
          )) as typeof import("../src/agent-session/acpmux/model");
          const rows = [...document.querySelectorAll<HTMLElement>("article[data-row-id]")];
          return texts.map((text) => {
            const row = rows
              .filter((one) => one.querySelector(".cv-user__body")?.textContent?.includes(text.split("\n").at(-1)!))
              .at(-1)!;
            const { width, height } = row.getBoundingClientRect();
            const estimate = layoutConversation([{ id: "fit", version: 1, at: 0, kind: "user", text }], width)
              .heights[0]!;
            return { text, drawn: height, estimate };
          });
        },
        [`> ${quote}\n\nYes, add README`, "What's in this folder?"],
      );
      for (const fit of fits)
        expect({ ...fit, off: Math.abs(fit.drawn - fit.estimate) < 1 }).toMatchObject({ off: true });
      // The card folds to the answer, not the quote.
      await page.locator(".acpmux-next-step--answered").first().waitFor({ timeout: 30_000 });
      expect(
        await page.locator(".acpmux-next-step--answered .acpmux-question-answered-answer").first().textContent(),
      ).toBe("Yes, add README");
      if (out) await page.screenshot({ path: path.join(out, "pane-wrap-up-answered-reply-dark.png") });
    } finally {
      await page.close();
    }
  });
});
