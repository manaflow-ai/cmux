// Browser check against a running mux: start a conversation, send a message,
// wait for the mux's reply, save a screenshot.
// Usage: bun scripts/e2e.ts [baseUrl] [message] [screenshot]
// With MUX_E2E_EMAIL and MUX_E2E_PASSWORD it signs in through the form;
// otherwise it uses a fresh development identity.
import { chromium } from "playwright-core";

const base = process.argv[2] ?? "http://localhost:8787";
const text = process.argv[3] ?? "Say hi in five words.";
const screenshot = process.argv[4] ?? "/tmp/mux-e2e.png";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 720 } });
  const email = process.env.MUX_E2E_EMAIL;
  if (email) {
    await page.goto(`${base}/sign-in`);
    await page.getByPlaceholder("Email").fill(email);
    await page.getByPlaceholder("Password").fill(process.env.MUX_E2E_PASSWORD ?? "");
    await page.getByRole("button", { name: "Sign in" }).click();
    await page.getByRole("button", { name: "New conversation" }).waitFor();
  } else {
    await page.goto(`${base}/?dev_user=e2e-${Date.now().toString(36)}`);
  }
  // A server with one conversation (the local mux) opens it directly.
  if (!/\/c\//.test(page.url())) {
    await page.getByRole("button", { name: "New conversation" }).click();
    await page.waitForURL(/\/c\//);
  }
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
