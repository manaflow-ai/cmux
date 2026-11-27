// l10n-allow-file: test fixture prompts and model names, not shipped UI.
// cmux-web-test-timeout: 400
//
// The model, effort and access picks keep the chosen value, and picking is smooth. Leo,
// 2026-11-17, of his new cmux NEXT chat (Codex, GPT-6.1 Sol, Full access): "we need to test out
// more of these permission related combinations in ci and whatnot so things are as people would
// expect + that chats settle with no unnecessary layout shifts after they start and all this
// picking models and effort levels and options are smooth and they don't randomly change to other
// things and that things are working as expected".
//
// The real pane against the real acpmux daemon and its stand-in Codex and Claude Code
// (support/realAcpmux.ts). The Codex catalog is a real one's shape: GPT-6.1 Sol and GPT-6 Astra,
// Astra the default, each with its own levels. A New Tab picks Sol, High and Full access, then:
//
//   - each pick changes its chip once, straight to the picked value (the chips' text on every
//     painted frame shows no other value in between);
//   - the first send starts the chat on all three (acpmux runs them: the session's own options);
//   - a reload of the page, and a restart of the daemon the page reconnects to, show the same;
//   - on a New Tab, switching to Claude Code and back to Codex lands on Sol, High and Full access
//     again, and the chat starts on them.
//
// No value changes to another by itself at any point: not Full access to the default mode, not
// Sol to another model, not the effort back to the model's default.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Page } from "playwright";
import { MODEL_PICKER } from "../src/agent-session/acpmux/composerSelectors";
import {
  chipValues,
  installWireLog,
  startValueSampler,
  takeValues,
  timeline,
  type ValueFrame,
} from "./support/chipValues";
import { COMPACT_MODEL_MENU, MODEL_ROW_NAME } from "./support/compactModelMenu";
import { installPaintedFrames } from "./support/paintedFrames";
import { paneUrl } from "./support/realAcpmux";
import { openRealPaneLane, realPaneLane, turnDone, withFailureDump, type RealPaneLane } from "./support/realPaneLane";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-picks-hold.test.ts", async () => {
  await realPaneLane("agent-pane-picks-hold.test.ts", async () => {
    setDefaultTimeout(360_000);
    const out = process.env.FAST_CHECKS_OUT;
    let lane: RealPaneLane;
    beforeAll(async () => {
      // The stand-in Codex answers a real catalog's shape (realAcpmux.ts CODEX_CATALOG). New chats
      // start in the harness's own mode (Settings > Agents), so Full access is a pick the person
      // makes, not the default that would hide a reset to it.
      lane = await openRealPaneLane({
        settings: { agents: { defaultPermissionMode: "standard" } },
      });
    });
    afterAll(async () => {
      await lane?.close();
    });

    const log: string[] = [];
    const note = (line: string) => {
      log.push(line);
      console.log(line);
    };

    /**
     * The chips once the page has drawn every value the daemon sent. The page paints its chips
     * before its acpmux link is up (a guess from the bundled catalog: Opus 5.5 on a Linux runner),
     * so first wait for the link (model.ts linkUp: not "disconnected", not "connecting…") and
     * for acpmux's harness list in the composer, then for painted frames.
     */
    async function settled(page: Page) {
      await page.waitForFunction(
        () => {
          const state = (window as any).cmuxAcpmuxDebug?.chatState?.();
          const connection = String(state?.connection ?? "disconnected");
          const up = connection !== "disconnected" && !connection.startsWith("connecting");
          return up && (state?.composerInputs?.catalog?.length ?? 0) > 0;
        },
        undefined,
        { timeout: 60_000 },
      );
      for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      return chipValues(page);
    }

    /** The values a pick showed: it must go from `before` straight to one matching `after`. */
    function oneStep(what: string, frames: ValueFrame[], key: "model" | "access", after: RegExp) {
      const seen = frames.map((frame) => frame[key]).filter((value, at, all) => at === 0 || value !== all[at - 1]);
      note(`${what}: ${seen.join(" -> ")}`);
      expect(seen.at(-1)).toMatch(after);
      expect(seen.length).toBeLessThanOrEqual(2);
      // The other chip did not move.
      const other = key === "model" ? "access" : "model";
      const others = new Set(frames.map((frame) => frame[other]));
      expect([...others]).toHaveLength(1);
    }

    /** Nothing changed in the window: one value per chip. */
    function held(what: string, frames: ValueFrame[], want: { model: RegExp; access: RegExp }) {
      // Every value each chip showed, in order: a value that left and came back counts twice.
      const steps = (key: "model" | "access") =>
        frames.map((f) => f[key]).filter((value, at, all) => at === 0 || value !== all[at - 1]);
      const models = steps("model");
      const access = steps("access");
      note(`${what}: model ${models.join(" -> ")}; access ${access.join(" -> ")}`);
      expect(models).toHaveLength(1);
      expect(access).toHaveLength(1);
      expect(models[0]).toMatch(want.model);
      expect(access[0]).toMatch(want.access);
    }

    async function openModelMenu(page: Page) {
      await page.locator(MODEL_PICKER).first().waitFor();
      await page.locator(MODEL_PICKER).first().click();
      const menu = page.locator(COMPACT_MODEL_MENU).first();
      await menu.waitFor();
      return menu;
    }

    async function pickModel(page: Page, harness: string | undefined, name: string) {
      const menu = await openModelMenu(page);
      if (harness) await menu.locator(`.acpmux-cols-tab[aria-label="${harness}"]`).first().click();
      const row = menu.locator("[role=option], [role=menuitemradio]").filter({ hasText: name }).first();
      // A missing row is a wrong start (the menu opened on another harness's tab), not a slow
      // click: say what the menu showed in 10 s instead of a bare 30 s click timeout. On
      // 2026-11-23 and 11-25 this step timed out on "GPT-6.1 Sol" with the menu on Claude Code's
      // tab, and each red took hours to read back from a failure dump (#56045, #56476).
      if (
        !(await row.waitFor({ timeout: 10_000 }).then(
          () => true,
          () => false,
        ))
      ) {
        const shown = await page.evaluate(() => {
          const menu = document.querySelector(".acpmux-cols, .acpmux-quick-menu");
          const text = (el: Element | null | undefined) => (el?.textContent ?? "").trim();
          const state = (window as any).cmuxAcpmuxDebug?.chatState?.();
          return {
            tab: text(menu?.querySelector(".acpmux-cols-tab[aria-selected=true]")) || "(no tabs)",
            rows: [...(menu?.querySelectorAll("[role=option], [role=menuitemradio]") ?? [])].map(text),
            connection: String(state?.connection ?? "unknown"),
            catalog: state?.composerInputs?.catalog?.length ?? 0,
          };
        });
        throw new Error(
          `model menu has no "${name}" row${harness ? ` on the ${harness} tab` : ""}: it shows tab ${shown.tab}, ` +
            `rows ${JSON.stringify(shown.rows)}; link ${shown.connection}, ${shown.catalog} harnesses from acpmux`,
        );
      }
      await row.locator(MODEL_ROW_NAME).first().click();
      await page.keyboard.press("Escape").catch(() => {});
    }

    async function pickEffort(page: Page, model: string, level: string) {
      const menu = await openModelMenu(page);
      // Focus the model's row (hover), then its level in the Reasoning column.
      await menu.locator("[role=option]").filter({ hasText: model }).first().hover();
      await menu.locator(".acpmux-cols-tune [role=radio]").filter({ hasText: level }).first().click();
      await page.keyboard.press("Escape").catch(() => {});
    }

    async function pickAccess(page: Page, name: RegExp) {
      await page.locator(".acpmux-access-trigger").first().click();
      const menu = page.locator(".acpmux-access-menu");
      await menu.waitFor();
      await menu.locator(".acpmux-access-item").filter({ hasText: name }).first().click();
      await page.waitForFunction(() => document.querySelector(".acpmux-access-menu") === null, undefined, {
        timeout: 5_000,
      });
    }

    /** What acpmux itself runs the chat on: its session's options, read on the relay's own line. */
    async function daemonPicks(sessionId: string) {
      const attach = await lane.daemon.call("_acpmux/attach", { sessionId, eventStream: false, limit: 1 });
      const session = attach?.session ?? {};
      const options: any[] = session.configOptions ?? attach?.configOptions ?? [];
      const current = Object.fromEntries(options.map((o) => [o.id, o.currentValue]));
      return { model: session.model, mode: session.mode ?? session.currentModeId, options: current };
    }

    const SOL = /Sol/;
    const HIGH = /High/;
    const FULL = /Full access/i;

    test("Sol, High and Full access hold through a first send, a reload, a daemon restart and a harness switch", async () => {
      const context = await lane.browser.newContext({ viewport: { width: 1100, height: 800 } });
      const page = await context.newPage();
      try {
        await withFailureDump(lane, page, "picks-hold", async () => {
          await installPaintedFrames(page);
          await installWireLog(page);
          await page.goto(paneUrl(lane.base, lane.daemon));
          await page.locator(".nt-field").waitFor();
          await page.waitForFunction(() => !!document.querySelector(".acpmux-access-trigger"));
          // The page draws a start before it has connected to acpmux (its own catalog's first
          // harness, Claude Code); the New Tab under test is the one acpmux names: its default
          // harness (Codex) on Codex's default model.
          await page.locator(MODEL_PICKER).filter({ hasText: "GPT-6 Astra" }).first().waitFor({ timeout: 90_000 });
          const start = await settled(page);
          note(`new tab: ${JSON.stringify(start)}`);
          // The start under test is acpmux's (Codex on GPT-6 Astra), not the page's pre-connect
          // guess (Opus 5.5): a wrong start fails here, by name, before any pick.
          expect(start.model).toMatch(/GPT-6 Astra/);
          await startValueSampler(page);
          await takeValues(page);

          await pickModel(page, undefined, "GPT-6.1 Sol");
          await settled(page);
          oneStep("pick Sol", await takeValues(page), "model", SOL);

          await pickEffort(page, "GPT-6.1 Sol", "High");
          await settled(page);
          oneStep("pick High", await takeValues(page), "model", HIGH);

          await pickAccess(page, FULL);
          await settled(page);
          oneStep("pick Full access", await takeValues(page), "access", FULL);
          const picked = await chipValues(page);
          const want = { model: new RegExp(`^${picked.model.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`), access: FULL };
          expect(picked.model).toMatch(SOL);
          expect(picked.model).toMatch(HIGH);

          // The first send.
          await page.locator(".nt-field").click();
          await page.keyboard.type("Add retry to the uploader");
          await page.keyboard.press("Enter");
          await page.locator(".acpmux-user").first().waitFor({ timeout: 30_000 });
          const sessionId = await turnDone(page);
          await settled(page);
          held("first send", await takeValues(page), want);
          const ran = await daemonPicks(sessionId);
          note(`acpmux runs: ${JSON.stringify(ran)}`);
          expect(String(ran.model)).toContain("gpt-6.1-sol");
          expect(JSON.stringify(ran.options)).toContain("high");

          // A reload of the page on the chat: a new document (a goto that changes only the hash
          // would keep this one), as the app's relaunch opens the tab.
          await page.goto("about:blank");
          await page.goto(paneUrl(lane.base, lane.daemon, `session=${sessionId}`));
          await page.locator(".acpmux-user").first().waitFor({ timeout: 30_000 });
          await page.waitForFunction(() => !!document.querySelector(".acpmux-access-trigger"));
          await startValueSampler(page);
          const reloaded = await settled(page);
          held("reload", await takeValues(page), want);
          expect(reloaded).toEqual(picked);

          // A restart of the daemon: the page loses its socket and reconnects to the new one.
          const before = lane.daemon.connections();
          await lane.daemon.restart();
          await page.waitForFunction(
            () => (window as any).cmuxAcpmuxDebug?.chatState?.().connection === "connected",
            undefined,
            { timeout: 60_000 },
          );
          expect(lane.daemon.connections()).toBeGreaterThan(before);
          await settled(page);
          held("daemon restart", await takeValues(page), want);
          const restarted = await daemonPicks(sessionId);
          note(`acpmux runs after restart: ${JSON.stringify(restarted)}`);
          expect(String(restarted.model)).toContain("gpt-6.1-sol");

          // A New Tab: Claude Code and back.
          await page.goto("about:blank");
          await page.goto(paneUrl(lane.base, lane.daemon));
          await page.locator(".nt-field").waitFor();
          await page.waitForFunction(() => !!document.querySelector(".acpmux-access-trigger"));
          note(`second new tab: ${JSON.stringify(await settled(page))}`);
          await startValueSampler(page);
          await takeValues(page);
          await pickAccess(page, FULL);
          await settled(page);
          await takeValues(page);
          await pickModel(page, "Claude Code", "Opus");
          note(`on Claude: ${JSON.stringify(await settled(page))}`);
          await takeValues(page);
          await pickModel(page, "Codex", "GPT-6.1 Sol");
          const back = await settled(page);
          note(`back on Codex: ${JSON.stringify(back)}`);
          const switched = await takeValues(page);
          expect(back.model).toMatch(SOL);
          expect(back.model).toMatch(HIGH);
          expect(back.access).toMatch(FULL);
          // The way back went straight to its values.
          expect(new Set(switched.map((f) => f.model)).size).toBeLessThanOrEqual(2);
          if (out) await page.screenshot({ path: path.join(out, "picks-hold.png") });
        });
      } finally {
        if (out) {
          mkdirSync(out, { recursive: true });
          const wire = await timeline(page).catch((error) => [String(error)]);
          writeFileSync(path.join(out, "picks-hold.txt"), [...log, "", "timeline (this page):", ...wire].join("\n"));
        }
        await context.close();
      }
    });
  });
});
