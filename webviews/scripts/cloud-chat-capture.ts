// l10n-allow-file: public-safe gallery fixture capture.
import { chromium } from "playwright";
import { createServer } from "vite";
import path from "node:path";
import { mkdir } from "node:fs/promises";

async function capture() {
  const root = path.resolve(import.meta.dir, "..");
  const vite = await createServer({
    root,
    configFile: path.join(root, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1" },
    logLevel: "warn",
  });
  const browser = await chromium.launch({ headless: true });
  try {
    await vite.listen();
    const address = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 620 } });
    await mkdir("/tmp/cloud-chat-captures", { recursive: true });
    for (const variant of ["before", "paused", "resuming", "deleted"]) {
      await page.goto(
        `http://127.0.0.1:${address.port}/gallery/frame.html?entry=agent-pane.cloud-chat-recovery&variant=${variant}&source=src/agent-session/acpmux/ChatUnavailableState.gallery.tsx&frame=component`,
      );
      const card = page.locator(".acpmux-unavailable");
      await card.waitFor({ timeout: 120_000 });
      if ((await card.count()) !== 1) throw new Error("Expected one unavailable card");
      const image = await card.screenshot({ path: `/tmp/cloud-chat-captures/${variant}.png` });
      console.log(`CLOUD_CHAT_CAPTURE:${variant}:${image.toString("base64")}`);
    }
  } finally {
    await browser.close();
    await vite.close();
  }
}
await capture();
