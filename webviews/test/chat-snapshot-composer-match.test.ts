// l10n-allow-file: test fixture composers (a chip's name, a queued prompt, a picker's label), not shipped UI.
// The last launch's copy gives way early only when the live composer shows what the copy's does
// (chatSnapshot/live.ts `promptMatchesChatSnapshot`, draftSettleHold.ts). Before, only the prompt's
// text was compared: a draft of one attachment and no text read as empty on both sides, the copy went
// before the live page put the chip back, and the composer grew by the chip's strip when it came
// (cmux#45669 review F1). Real Chromium, the copy in a shadow root over the live root as paint.ts
// draws it. Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/chat-snapshot-composer-match.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-snapshot-composer-match.test.ts", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser;
  let live = "";
  beforeAll(async () => {
    const entry = path.resolve(import.meta.dir, "../src/agent-session/acpmux/chatSnapshot/live.ts");
    const built = await Bun.build({ entrypoints: [entry], format: "esm", target: "browser" });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    // The module as a global, so the page calls it after the markup is in.
    live = (await built.outputs[0]!.text()).replace(/export\s*\{([^}]*)\};?\s*$/, (_m, names: string) => {
      const pairs = names.split(",").map((pair) => pair.trim().split(/\s+as\s+/));
      return `window.snapshotLive = {${pairs.map(([local, name]) => `${name ?? local}: ${local}`).join(",")}};`;
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const CSS = `
    body { margin: 0; font: 14px/20px sans-serif; }
    .acpmux-composer { width: 600px; }
    .acpmux-attachments { display: flex; gap: 6px; margin: 0; padding: 6px; border: 0; }
    .acpmux-attachment-slot { width: 64px; height: 64px; }
    .acpmux-attachment-slot img { width: 64px; height: 64px; display: block; }
    .acpmux-queued { height: 32px; }
    .acpmux-composer-box { min-height: 40px; }
    .acpmux-composer-bar { height: 28px; }
  `;
  type Parts = { text?: string; chip?: boolean; queued?: string; model?: string };
  /// The composer's markup as Composer.tsx draws it, in the parts the swap could step back.
  const composer = ({ text = "", chip = false, queued, model = "Model" }: Parts) =>
    `<div class="acpmux-composer">` +
    (queued ? `<div class="acpmux-composer-queue"><div class="acpmux-queued">${queued}</div></div>` : "") +
    (chip
      ? `<fieldset class="acpmux-attachments"><div class="acpmux-attachment-slot"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></div></fieldset>`
      : "") +
    `<div class="acpmux-composer-box"><div class="acpmux-md-root">${text}</div></div>` +
    `<div class="acpmux-composer-bar"><button>${model}</button></div></div>`;

  /// A page with the copy (`copy`) drawn over the live root (`now`); returns whether the live page's
  /// composer matches the copy's, and both composers' heights.
  async function compare(page: Page, copy: Parts, now: Parts) {
    await page.setContent(
      `<!doctype html><html><head><style>${CSS}</style></head><body><main id="root">${composer(now)}</main></body></html>`,
    );
    await page.addScriptTag({ content: live });
    return await page.evaluate(
      ({ markup, css }) => {
        const host = document.createElement("cmux-chat-snapshot");
        const shadow = host.attachShadow({ mode: "open" });
        shadow.innerHTML = `<style>${css}</style><div>${markup}</div>`;
        document.body.append(host);
        (window as any).__cmuxChatSnapshotShown = { at: 0 };
        const height = (scope: ParentNode) => scope.querySelector(".acpmux-composer")!.getBoundingClientRect().height;
        return {
          matches: (window as any).snapshotLive.promptMatchesChatSnapshot() as boolean,
          copy: height(shadow),
          live: height(document.getElementById("root")!),
        };
      },
      { markup: composer(copy), css: CSS },
    );
  }

  test("an attachment-only draft the live composer has not put back yet does not match: the copy stays", async () => {
    const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    try {
      const early = await compare(page, { chip: true }, {});
      // The swap here would grow the composer by the chip's strip.
      expect(early.live).toBeLessThan(early.copy);
      expect(early.matches).toBe(false);
      // Once the chip is back the composer is as tall as the copy's, and the copy may go.
      const back = await compare(page, { chip: true }, { chip: true });
      expect(back.live).toBe(back.copy);
      expect(back.matches).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("a queued prompt or a pick the live composer restores later does not match either", async () => {
    const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    try {
      expect((await compare(page, { text: "draft", queued: "next prompt" }, { text: "draft" })).matches).toBe(false);
      expect((await compare(page, { text: "draft", model: "Opus" }, { text: "draft" })).matches).toBe(false);
      expect((await compare(page, { text: "draft" }, { text: "draft" })).matches).toBe(true);
      expect((await compare(page, {}, {})).matches).toBe(true);
    } finally {
      await page.close();
    }
  });
});
