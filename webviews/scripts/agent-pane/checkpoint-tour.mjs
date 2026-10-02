#!/usr/bin/env node
// Portable interaction proof for the real pane/controller against a simulated native Git owner.
// Live repository capture is tested separately with the session-host implementation.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";
const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
process.chdir(webviews);
const out = path.resolve(process.argv[2] ?? path.join(webviews, "../artifacts/checkpoint-pane"));
await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0 },
  logLevel: "error",
});
await server.listen();
const browser = await chromium.launch();
const observations = [];
try {
  for (const variant of ["compact", "expanded"]) {
    const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, colorScheme: "dark" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(() => {
      const limits = { max_bytes: 134217728, max_files: 1000, max_untracked_file_bytes: 10000000 };
      const candidates = [
        { path: "USER_NOTES.md", bytes: 120, eligible: true },
        { path: "draft.txt", bytes: 32, eligible: true },
        { path: "large.bin", bytes: 10000000, eligible: false, reason: "over_limit" },
      ];
      const state = (window.checkpointTour = { calls: [], creates: 0, caps: 0, unsupported: false, record: null });
      window.webkit = {
        messageHandlers: {
          agentSession: {
            postMessage: async ({ method, params }) => {
              state.calls.push({ method, params });
              const success = (value) => ({ ok: true, value });
              if (method === "ready") return success({ protocolVersion: 1, transport: "mock" });
              if (method === "git.capabilities") {
                state.caps++;
                return success({ checkpoints: true });
              }
              if (method === "git.checkpoint.list") {
                if (state.unsupported)
                  return {
                    ok: false,
                    error: {
                      code: "operation.unsupported",
                      origin: "session_host",
                      userMessage: "Checkpoints unavailable",
                    },
                  };
                return success({
                  repository_id: "sample-repo",
                  worktree_id: "sample-worktree",
                  checkpoints: [],
                  next_cursor: null,
                  candidates,
                  limits,
                });
              }
              if (method === "git.checkpoint.create") {
                state.creates++;
                state.record = {
                  checkpoint_id: "checkpoint-1",
                  repository_id: "sample-repo",
                  worktree_id: "sample-worktree",
                  ref: "refs/cmux/checkpoints/sample-worktree/checkpoint-1",
                  object_id: "a".repeat(40),
                  revision: "1",
                  complete: false,
                  skipped: [
                    { path: "draft.txt", code: "not_selected" },
                    { path: "large.bin", code: "over_limit", bytes: 10000000 },
                  ],
                  skipped_total: 2,
                  created_at: "2026-10-02T12:00:00Z",
                  expires_at: "2026-10-09T12:00:00Z",
                  base: { head: "b".repeat(40), branch: "main", detached: false },
                  coverage: { included: 3, omitted: 2, unavailable: 0 },
                  included: { tracked: 2, untracked: 1, staged_entries: 1 },
                  bytes: { logical: 472, newly_stored: 248 },
                  limits,
                  pins: [],
                };
                state.key = params.idempotency_key;
                return {
                  ok: false,
                  error: {
                    code: "native.timed_out",
                    origin: "native",
                    userMessage: "The reply was lost. Check the saved checkpoint before retrying.",
                  },
                };
              }
              if (method === "git.checkpoint.get") return success(state.record);
              if (method === "git.checkpoint.pin") {
                state.record = {
                  ...state.record,
                  revision: "2",
                  pins: [{ pin_id: params.pin_id, reason: params.reason }],
                };
                return success({ result: state.record, revision: "2", replayed: false });
              }
              if (method === "git.checkpoint.unpin") {
                state.record = { ...state.record, revision: "3", pins: [] };
                return success({ result: state.record, revision: "3", replayed: false });
              }
              return success(null);
            },
          },
        },
      };
    });
    await page.goto(`${server.resolvedUrls.local[0]}?checkpointVariant=${variant}`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.cmuxAcpmuxActions?.["chat.send"]);
    await page.evaluate((theme) => window.cmuxAcpmuxBridge.applyTheme(theme), agentPaneTheme(ghosttyDefault));
    const headerAction = page.locator(".acpmux-header").getByRole("button", { name: "Create checkpoint", exact: true });
    await headerAction.click();
    const review = page.getByRole("region", { name: "Repository checkpoint", exact: true });
    await review.getByLabel("draft.txt", { exact: true }).uncheck();
    await page.screenshot({ path: path.join(out, `${variant}-review.png`) });
    assert.equal(await page.evaluate(() => window.checkpointTour.creates), 0);
    await review.getByRole("button", { name: "Create", exact: true }).click();
    await review.getByRole("button", { name: "Retry", exact: true }).waitFor();
    assert.equal(await review.getByRole("button", { name: "Create", exact: true }).isDisabled(), true);
    await page.screenshot({ path: path.join(out, `${variant}-uncertain.png`) });
    await review.getByRole("button", { name: "Retry", exact: true }).click();
    await review.getByText("Partial checkpoint", { exact: true }).waitFor();
    const intent = await page.evaluate(() =>
      window.checkpointTour.calls.find((call) => call.method === "git.checkpoint.create"),
    );
    assert.deepEqual(intent.params.include_untracked, ["USER_NOTES.md"]);
    assert.equal(await page.evaluate(() => window.checkpointTour.creates), 1);
    await review.getByRole("button", { name: "Keep checkpoint", exact: true }).click();
    await review.getByRole("button", { name: "Release pin", exact: true }).waitFor();
    await page.screenshot({ path: path.join(out, `${variant}-receipt.png`) });
    await review.getByRole("button", { name: "Release pin", exact: true }).click();
    await review
      .getByText("Use Keep checkpoint before sharing this reference in a manual handoff.", { exact: true })
      .waitFor();
    await review.getByRole("button", { name: "Cancel", exact: true }).click();
    // The native palette enters exactly the same show path, not another capture path.
    await page.evaluate(() => window.cmuxAcpmuxBridge.command("createCheckpoint"));
    await review.getByRole("button", { name: "Create", exact: true }).waitFor();
    const scope = await page.evaluate(() => window.checkpointTour);
    assert.equal(scope.caps, 1);
    assert.equal(scope.calls.filter((call) => call.method === "git.checkpoint.list").length, 2);
    await page.evaluate(() => {
      window.checkpointTour.unsupported = true;
    });
    await review.getByRole("button", { name: "Refresh", exact: true }).click();
    await headerAction.waitFor({ state: "detached" });
    assert.equal(await review.count(), 0);
    assert.deepEqual(errors, []);
    observations.push(
      `${variant}: opening only reads, exact untracked approval, timeout recovery without a second create, partial receipt, keep/release, palette shared path, one capability read, unsupported hides actions.`,
    );
    await context.close();
  }
  await fs.writeFile(
    path.join(out, "observations.json"),
    JSON.stringify({ simulatedOwner: true, observations }, null, 2),
  );
  process.stdout.write(`${observations.join("\n")}\n`);
} finally {
  await browser.close();
  await server.close();
}
