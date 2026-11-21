// l10n-allow-file: test fixtures.
// The CSS that styled a message's DisclosureRow reaches the one message row (AgentMessageRow.tsx)
// that every message between agents now draws (cmux#37653): in an opened waiting group
// (PendingMessagesCard.css) a sender's lines leave out the name its head already says, and an opened
// message card's corner copy (CardCopy.css) lights when the card is hovered and keeps its float in a
// card shorter than the button. Real Chromium on the pane's CSS (browser/agent-message-row-css.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-message-row-css-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/agent-message-row-css.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/agent-message-row-css.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("agent message row CSS", () => {
    test("an opened waiting group's lines leave out the sender its head names", async () => {
      const pending = page.getByTestId("pending");
      await pending.locator(".cv-pending__toggle").click();
      const senders = pending.locator(".cv-pending__sender .cv-agentmsg__line .cv-received__sender");
      await expect(senders.count()).resolves.toBe(2);
      for (const display of await senders.evaluateAll((all) => all.map((node) => getComputedStyle(node).display)))
        expect(display).toBe("none");
      // The head still names it.
      await expect(pending.locator(".cv-pending__sender-head .cv-received__sender").isVisible()).resolves.toBe(true);
    });

    test("an opened message card's corner copy lights when the card is hovered", async () => {
      const received = page.getByTestId("received");
      await received.locator(".cv-agentmsg__toggle").click();
      const copy = received.locator(".cv-agentmsg__card > .cv-card-copy");
      await expect(copy.count()).resolves.toBe(1);
      await page.mouse.move(0, 599);
      expect(Number(await copy.evaluate((node) => getComputedStyle(node).opacity))).toBeLessThan(1);
      await received.locator(".cv-agentmsg__card").hover({ position: { x: 4, y: 4 } });
      await page.waitForFunction(
        // The received row's own card: an earlier test's opened group draws cards above it.
        () =>
          getComputedStyle(document.querySelector('[data-testid="received"] .cv-agentmsg__card > .cv-card-copy')!)
            .opacity === "1",
        undefined,
        { timeout: 2_000 },
      );
    });

    test("a long first line gives way before the sender's name", async () => {
      const row = page.getByTestId("long-preview");
      const sizes = await row.locator(".cv-agentmsg__line").evaluate((line) => {
        const cut = (node: Element | null) =>
          node ? { scroll: node.scrollWidth, client: node.clientWidth } : { scroll: -1, client: -1 };
        const sender = line.querySelector(".cv-received__sender");
        return {
          sender: cut(sender),
          label: cut(sender?.querySelector(".cv-agent-tag__label") ?? null),
          preview: cut(line.querySelector(".cv-agentmsg__preview")),
          text: sender?.textContent ?? "",
        };
      });
      expect(sizes.text).toContain("summary-panel");
      // The preview is the one cut.
      expect(sizes.preview.scroll).toBeGreaterThan(sizes.preview.client);
      // The name is whole: neither its part of the line nor its label inside the chip is cut.
      expect(sizes.sender.scroll).toBeLessThanOrEqual(sizes.sender.client);
      expect(sizes.label.scroll).toBeLessThanOrEqual(sizes.label.client);
    });

    // At a 320px pane a sender's name wider than the line is cut inside its chip, behind an ellipsis,
    // never clipped bare at the line's end (cmux#37653 review).
    test("a sender's name wider than a narrow line ends in an ellipsis inside its chip", async () => {
      const sizes = await page
        .getByTestId("narrow-sender")
        .locator(".cv-agentmsg__line")
        .evaluate((line) => {
          const tag = line.querySelector<HTMLElement>(".cv-received__sender > .cv-agent-tag")!;
          // The node that holds the name's text: the open chip's label, else the plain tag.
          const label = tag.querySelector<HTMLElement>(".cv-agent-tag__label") ?? tag;
          return {
            text: label.textContent ?? "",
            overflow: getComputedStyle(label).textOverflow,
            cut: label.scrollWidth > label.clientWidth,
            end: label.getBoundingClientRect().right,
            // The words end before the chevron, and the chevron inside the line.
            chevron: line.querySelector(".cv-agentmsg__chevron")!.getBoundingClientRect().toJSON() as DOMRect,
            lineEnd: line.getBoundingClientRect().right,
          };
        });
      expect(sizes.text).toContain("release-rings-coordinator");
      expect(sizes.overflow).toBe("ellipsis");
      // The chip's own box cuts it, so its ellipsis shows inside the line; the line's overflow never
      // cuts it bare, and the chevron stays in view after it.
      expect(sizes.cut).toBe(true);
      expect(sizes.end).toBeLessThanOrEqual(sizes.chevron.left + 0.5);
      expect(sizes.chevron.right).toBeLessThanOrEqual(sizes.lineEnd + 0.5);
    });

    // At a middle width the first line gives way first: its preview is cut while the sender's name
    // still fits whole, so an ordinary narrow row never cuts the name (cmux#38642 review: a sender
    // shrinking at 1 took its share of every overflow from the first pixel).
    test("a sender's name stays whole while its first line still has room to give", async () => {
      const sizes = await page
        .getByTestId("middle-sender")
        .locator(".cv-agentmsg__line")
        .evaluate((line) => {
          const tag = line.querySelector<HTMLElement>(".cv-received__sender > .cv-agent-tag")!;
          const label = tag.querySelector<HTMLElement>(".cv-agent-tag__label") ?? tag;
          const preview = line.querySelector<HTMLElement>(".cv-agentmsg__preview")!;
          return {
            text: label.textContent ?? "",
            // Fractional widths: the sender's weighted share of the overflow is under a pixel, which
            // scrollWidth's rounding hides, yet it is enough to draw the ellipsis.
            nameCut: (() => {
              const words = document.createRange();
              words.selectNodeContents(label);
              return words.getBoundingClientRect().width - label.getBoundingClientRect().width;
            })(),
            previewCut: preview.scrollWidth > preview.clientWidth,
            previewWidth: preview.getBoundingClientRect().width,
            chevron: line.querySelector(".cv-agentmsg__chevron")!.getBoundingClientRect().toJSON() as DOMRect,
            lineEnd: line.getBoundingClientRect().right,
          };
        });
      expect(sizes.text).toContain("release-rings-coordinator");
      expect(sizes.previewCut).toBe(true);
      expect(sizes.previewWidth).toBeGreaterThan(0);
      expect(sizes.nameCut).toBeLessThanOrEqual(0.01);
      expect(sizes.chevron.right).toBeLessThanOrEqual(sizes.lineEnd + 0.5);
    });

    // A sent message draws as a received one (cmux#37879) on the one message row: its own rules in
    // AgentMessageRow.css reach it. A merge once left a rule above them unclosed, nesting them all
    // under a button's selector, where none of them matched (cmux#37653 review).
    test("a sent row's own rules apply: the chip's pull, the sender's shrink, the status's room", async () => {
      const styles = await page
        .getByTestId("sent")
        .locator(".cv-sent-msg > .cv-agentmsg__line")
        .evaluate((line) => {
          const style = (selector: string) => {
            const node = line.querySelector(selector);
            return node ? getComputedStyle(node) : undefined;
          };
          const chip = line.querySelector(".cv-received__sender > .cv-agent-tag");
          return {
            chipOpen: chip?.classList.contains("is-open") ?? false,
            chipPull: style(".cv-received__sender > .cv-agent-tag")?.marginInlineStart,
            senderShrink: style(":scope > .cv-agentmsg__sentence > .cv-received__sender")?.flexShrink,
            trailShrink: style(":scope > .cv-tool__trail")?.flexShrink,
            status: Boolean(line.querySelector(".cv-tool__trail .cv-row-status")?.textContent),
          };
        });
      expect(styles).toEqual({
        chipOpen: true,
        chipPull: "0px",
        senderShrink: "1",
        trailShrink: "0",
        status: true,
      });
    });

    test("a failed send's mark is drawn in the failure colour", async () => {
      const colors = await page
        .getByTestId("sent-failed")
        .locator(".cv-sent-msg")
        .evaluate((row) => {
          const probe = document.createElement("span");
          probe.style.color = "var(--agent-status-failure)";
          row.append(probe);
          const failure = getComputedStyle(probe).color;
          probe.remove();
          const mark = row.querySelector(".cv-agentmsg__icon > .cv-received__mark.cv-tool__failed");
          return { mark: mark ? getComputedStyle(mark).color : "none", failure };
        });
      expect(colors.mark).toBe(colors.failure);
    });

    test("an opened message card holds its floated corner copy", async () => {
      const card = page.getByTestId("received").locator(".cv-agentmsg__card");
      await expect(card.evaluate((node) => getComputedStyle(node).display)).resolves.toBe("flow-root");
    });
  });
});
