// Capture every agent question fixture (acpmux-preview `question-*`) in dark and light, and drive
// the keys of one pending card. Presentation evidence; question/*.test.ts* own the behavior.
//   node scripts/agent-pane/question-cards-smoke.mjs [out dir]
import path from "node:path";
import fs from "node:fs/promises";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = path.resolve(process.argv[2] ?? path.join(webviews, "dist/question-cards"));
const FIXTURES = [
  "pending-single",
  "pending-multi",
  "pending-with-preview",
  "pending-4-questions",
  "pending-other-typing",
  "answered-collapsed",
  "answered-remote-device",
  "cancelled",
  "codex-user-input",
  "acp-interactive",
  "chief-asks",
];
await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-preview.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
});
await server.listen();
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({ viewport: { width: 980, height: 820 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const { port } = server.httpServer.address();
  const card = () => page.locator(".acpmux-question, .acpmux-question-answered, .acpmux-question-cancelled").first();
  for (const theme of ["dark", "light"]) {
    for (const name of FIXTURES) {
      await page.goto(`http://127.0.0.1:${port}/?fixture=question-${name}`);
      if (theme === "light") await page.getByRole("button", { name: "Toggle light" }).click();
      await card().waitFor();
      await page.locator(".acpmux-shell").screenshot({ path: path.join(out, `${name}-${theme}.png`) });
    }
  }
  // Keys: the card never takes focus on arrival; Tab reaches the first row, arrows move the
  // highlight (and the preview), Escape hands the keyboard back.
  await page.goto(`http://127.0.0.1:${port}/?fixture=question-pending-with-preview`);
  await card().waitFor();
  assert.equal(await page.evaluate(() => !!document.activeElement?.closest(".acpmux-question")), false);
  await page.locator(".acpmux-question-row").first().focus();
  await page.keyboard.press("ArrowDown");
  assert.match(await page.locator(".acpmux-question-preview pre").innerText(), /┌ General ┬ Keys/);
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "pending-with-preview-arrow-down.png") });
  await page.keyboard.press("Escape");
  assert.equal(await page.evaluate(() => !!document.activeElement?.closest(".acpmux-question")), false);
  // A number key answers: the preview bridge clears the permission.
  await page.goto(`http://127.0.0.1:${port}/?fixture=question-pending-multi`);
  await page.locator(".acpmux-question-row").first().focus();
  await page.keyboard.press("1");
  await page.keyboard.press("4");
  await page.locator(".acpmux-shell").screenshot({ path: path.join(out, "pending-multi-chosen.png") });
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => !document.querySelector(".acpmux-question"));
  assert.deepEqual(errors, []);
  console.log(`Question cards: ${FIXTURES.length} fixtures x 2 themes captured; keys passed.`);
  console.log(out);
} finally {
  await browser?.close();
  await server.close();
}
