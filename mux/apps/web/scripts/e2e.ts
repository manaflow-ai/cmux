// Browser check against a running mux: start a conversation, send a message,
// wait for the mux's reply, save a screenshot.
// Usage: bun scripts/e2e.ts [baseUrl] [message] [screenshot]
import { chromium } from "playwright-core";

const base = process.argv[2] ?? "http://localhost:8787";
const text = process.argv[3] ?? "Say hi in five words.";
const screenshot = process.argv[4] ?? "/tmp/mux-e2e.png";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 720 } });
  await page.goto(`${base}/?dev_user=e2e-${Date.now().toString(36)}`);
  await page.getByRole("button", { name: "New conversation" }).click();
  await page.waitForURL(/\/c\//);
  await page.getByPlaceholder("Message").fill(text);
  await page.keyboard.press("Enter");
  await page.locator(".bubble-row.mine .bubble:not(.sending)").first().waitFor();
  await page
    .locator(".bubble-row:not(.mine) .bubble:not(.typing)")
    .first()
    .waitFor({ timeout: 120_000 });
  const reply = await page
    .locator(".bubble-row:not(.mine) .bubble:not(.typing)")
    .last()
    .innerText();
  await page.screenshot({ path: screenshot });
  console.log(JSON.stringify({ reply, screenshot }));
} finally {
  await browser.close();
}
