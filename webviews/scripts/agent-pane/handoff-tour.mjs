#!/usr/bin/env node
// Portable pane interaction proof against the mock daemon. Live harness dogfood is separate.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";
const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
process.chdir(webviews);
const out = path.resolve(process.argv[2] ?? path.join(webviews, "../artifacts/handoff-pane"));
await fs.mkdir(out, { recursive: true });
const server = await createServer({ configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"), server: { port: 0 }, logLevel: "error" });
await server.listen();
const browser = await chromium.launch();
const observations = [];
try {
  const context = await browser.newContext({ viewport: { width: 1200, height: 1000 }, colorScheme: "dark", recordVideo: { dir: out } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
  });
  await page.goto(server.resolvedUrls.local[0], { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.cmuxAcpmuxActions?.["chat.handoff.prepare"]);
  await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(ghosttyDefault));
  const actions = (name, params = {}) => page.evaluate(({ name, params }) => window.cmuxAcpmuxActions[name](params), { name, params });
  await actions("chat.new", { harness: "claude" });
  const source = await actions("pane.context");
  await page.getByRole("button", { name: "Continue in…", exact: true }).click();
  await page.getByRole("menuitem", { name: "Codex", exact: true }).click();
  const review = page.getByRole("region", { name: "Review continuation" });
  await review.waitFor();
  assert.equal(await page.locator(".acpmux-composer").count(), 0, "ordinary composer hidden until review starts");
  assert.equal(await review.getByRole("button", { name: "Continue in Codex", exact: true }).isDisabled(), true);
  await review.getByLabel("Context to carry forward", { exact: true }).fill("Continue the dirty repository task. Preserve tracked changes and the untracked user note.");
  await review.getByLabel("Repository checkpoint", { exact: true }).fill("manual-backup-1");
  await review.getByLabel("I saved the working changes, including the files I need to keep.", { exact: true }).check();
  await review.getByText("Approved memory references", { exact: true }).click();
  await review.getByLabel("Share only the references you approve for this chat, one per line.", { exact: true }).fill("project/approved-rule");
  await review.getByText("Carried context", { exact: true }).click();
  await page.screenshot({ path: path.join(out, "claude-to-codex-review.png") });
  await review.getByRole("button", { name: "Continue in Codex", exact: true }).click();
  await review.waitFor({ state: "detached" });
  await page.locator(".acpmux-composer").waitFor();
  await page.waitForFunction(() => document.querySelector(".acpmux-status")?.textContent !== "Working");
  observations.push("Claude to Codex: no composer before review; checkpoint attested; approved memory reference; one start; review removed.");
  // Palette bridge opens the same header chooser for the reverse direction.
  await page.evaluate(() => window.cmuxAcpmuxBridge.command("continueIn"));
  await page.getByRole("menuitem", { name: "Claude Code", exact: true }).click();
  await review.waitFor();
  await page.screenshot({ path: path.join(out, "codex-to-claude-review.png") });
  await review.getByRole("button", { name: "Discard continuation", exact: true }).click();
  await review.waitFor({ state: "detached" });
  const after = await actions("pane.context");
  assert.equal(after.cwd, source.cwd, "handoff preserves the working directory");
  observations.push("Codex to Claude: palette bridge opens header chooser; discard returns to Codex with the same cwd.");
  assert.deepEqual(errors, []);
  await page.screenshot({ path: path.join(out, "discard-returned-to-codex.png") });
  await context.close();
  await fs.writeFile(path.join(out, "observations.json"), JSON.stringify({ transport: "mock", observations, errors }, null, 2) + "\n");
  console.log(JSON.stringify({ out, observations }));
} finally { await browser.close(); await server.close(); }
