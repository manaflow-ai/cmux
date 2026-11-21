#!/usr/bin/env node
// The first-user journey matrix for cmux NEXT's webviews: every harness the model picker lists, in
// each of four states (not installed, installed and signed out, signed in with a spent plan, signed in
// and working), walked the way a first user clicks around, with a "no busted state" verdict per step.
//
//   bun run journey:first-user [--out DIR] [--only CELL,...] [--workers N] [--max-controls N] [--no-video]
//
// Each cell runs in its own browser context against the dev server (vite.config.ts) and the mock
// daemon, which serves that cell (`?mock&journey=HARNESS:STATE`, src/agent-session/acpmux/journeyFixture.ts):
//   pane/new-chat     a new chat's first paint, and every control on it
//   pane/picker       the harness and model picker, and each entry in it
//   pane/first-prompt the cell's harness picked, a first prompt sent, and the reply or error it gets
//   pane/harnesses    the pane's Harnesses page
//   settings/agents   Settings > Agents, where the harnesses are listed
// The pages that do not depend on the harness (every src/pages/<page>/mockProvider.ts, and every
// Settings section) run once each as their own cells (`pages/<page>`), not once per harness.
//
// Rules (src/devkit/firstUserJourney/rules.ts), each named so reds group by class: error-without-next-step, raw-error-code,
// dead-button, permanent-spinner, layout-break (1280x800 and 800x600), console-error, crash.
//
// Writes <out>/results.json (the shared first-user journey schema, surface "web"), <out>/steps.json
// (every step with every rule's verdict and its screenshot), <out>/summary.md, and per cell
// <out>/cells/<cell>/NN-*.png and video.webm. Exits 0 whatever it finds; a runner failure exits 1.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { launchBrowser, settle, startDevServer, stubMockBridge, webviews } from "../agent-pane/mockLaunch.mjs";

const RULES = [
  "error-without-next-step",
  "raw-error-code",
  "dead-button",
  "permanent-spinner",
  "layout-break",
  "console-error",
  "crash",
];
const STATES = ["not-installed", "signed-out", "expired", "working"];
/// Text the browser-only mock shows where the app would answer (no native host): never a red.
const MOCK_ARTIFACTS = ["The app is not connected to this pane."];
/// Reds that are a settled design, each with who settled it: listed in the summary as allowed, never a red.
const ALLOWED = [
  {
    rule: "dead-button",
    detail: '"Context window" is disabled with no reason shown',
    why: "the context ring is inert with no tooltip before the first usage report (Lucas 2026-11-11, ComposerPickers.tsx)",
  },
];
const SPINNER_GRACE_MS = 10_000;
const PLACEHOLDER_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
  "base64",
);
const VIEWPORT = { width: 1280, height: 800 };
const SMALL = { width: 800, height: 600 };

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  if (index < 0) return fallback;
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`--${name} needs a value`);
  return value;
};
const flag = (name) => args.includes(`--${name}`);
const outRoot = path.resolve(
  option("out", process.env.FAST_CHECKS_OUT || path.join(os.tmpdir(), "first-user-journey")),
);
const only = option("only", "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const workers = Math.max(1, Number(option("workers", process.env.CMUX_JOURNEY_WORKERS || "4")));
/// A dev flag only: the full run clicks every control a surface shows.
const maxControls = Number(option("max-controls", "Infinity"));
const video = !flag("no-video");

fs.rmSync(path.join(outRoot, "cells"), { recursive: true, force: true });
fs.mkdirSync(outRoot, { recursive: true });

/// The harnesses the picker lists (the bundled catalog's, as the page has them) and the journey
/// fixture's, and every page with a mock provider.
async function discover() {
  const context = await browser.newContext();
  const page = await context.newPage();
  // The first load compiles the pane: give it time once, here, not in every cell.
  await page.goto(`${base}/agent-pane/?mock`, { waitUntil: "load", timeout: 300_000 });
  const harnesses = await page.evaluate(async () => {
    const catalog = await import("/src/agent-session/acpmux/modelCatalogData.ts");
    const fixture = await import("/src/agent-session/acpmux/journeyFixture.ts");
    const ids = catalog.BUNDLED_MODEL_CATALOG.harnesses.map((harness) => harness.id);
    for (const id of fixture.JOURNEY_HARNESSES) if (!ids.includes(id)) ids.push(id);
    return ids;
  });
  await page.goto(`${base}/settings/?mock`, { waitUntil: "load", timeout: 300_000 });
  await context.close();
  const pages = fs
    .readdirSync(path.join(webviews, "src/pages"))
    .filter((name) => fs.existsSync(path.join(webviews, "src/pages", name, "mockProvider.ts")))
    .filter((name) => fs.existsSync(path.join(webviews, "src/pages", name, "main.tsx")))
    .sort();
  return { harnesses, pages };
}

async function runCell(cell) {
  const t0 = Date.now();
  const dir = path.join(outRoot, "cells", cell.id.replace(/\//g, "__"));
  fs.mkdirSync(dir, { recursive: true });
  const context = await browser.newContext({
    viewport: VIEWPORT,
    colorScheme: "dark",
    ...(video ? { recordVideo: { dir, size: VIEWPORT } } : {}),
  });
  // Nothing leaves this machine: a link to the web is a way out of the app, recorded, not followed.
  await context.route(/^https?:\/\/(?!127\.0\.0\.1|localhost)/, (route) => route.abort());
  // Settings draws menu symbols and wallpaper thumbnails from the app host (cmux-page://cmux.settings/
  // symbol/<name>, backdrop/<id>); the dev server has none, so a 404 there is the mock, not the page.
  await context.route(/\/settings\/(?:symbol|backdrop)\//, (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: PLACEHOLDER_PNG }),
  );
  const page = await context.newPage();
  const walk = new Walk(cell, page, dir);
  try {
    await instrument(page);
    if (cell.page) await pagesCell(walk, cell);
    else await harnessCell(walk, cell);
  } catch (error) {
    walk.red("crash", "runner", "cell", `the run stopped: ${String(error?.message ?? error).split("\n")[0]}`);
    await walk.shot("crash").catch(() => undefined);
  }
  const videoFile = page.video();
  await context.close();
  if (videoFile) await fs.promises.rename(await videoFile.path(), path.join(dir, "video.webm")).catch(() => undefined);
  return walk.result(Date.now() - t0);
}

/// Counters the in-page checks read: clipboard writes, windows opened, mock daemon requests, host calls.
async function instrument(page) {
  page.on("dialog", (dialog) => dialog.dismiss().catch(() => undefined));
  page.on("popup", (popup) => popup.close().catch(() => undefined));
  await page.addInitScript(() => {
    const counters = { clipboard: 0, open: 0, rpc: [], host: [], mutations: 0 };
    window.__fujCounters = counters;
    // Attribute changes a click makes (aria-checked, aria-expanded, a class), never the walk's own mark.
    new MutationObserver((records) => {
      for (const record of records)
        if (
          record.type !== "attributes" ||
          (record.attributeName !== "style" && record.attributeName !== "data-fuj-target")
        )
          counters.mutations += 1;
    }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    const clipboard = navigator.clipboard;
    if (clipboard) {
      for (const name of ["writeText", "write"]) {
        const original = clipboard[name]?.bind(clipboard);
        clipboard[name] = (...values) => {
          counters.clipboard += 1;
          return original ? original(...values).catch(() => undefined) : Promise.resolve();
        };
      }
    }
    const exec = document.execCommand.bind(document);
    document.execCommand = (command, ...rest) => {
      if (command === "copy") counters.clipboard += 1;
      return exec(command, ...rest);
    };
    window.open = () => {
      counters.open += 1;
      return null;
    };
    // An unhandled rejection reaches the console as an error, like an uncaught throw.
    window.addEventListener("unhandledrejection", (event) =>
      console.error(`unhandled rejection: ${event.reason?.message ?? String(event.reason)}`),
    );
  });
}

/// After a pane load: the mock daemon's requests and the page's host calls are counted too.
async function instrumentPane(page) {
  await page.evaluate(async () => {
    const counters = window.__fujCounters;
    const mock = await import("/src/agent-session/acpmux/mock.ts");
    const proto = mock.MockAcpmuxSocket.prototype;
    if (!proto.__fujSend) {
      proto.__fujSend = proto.send;
      // Reads the page makes by itself (watch, paging, polls) are not a click's doing.
      const quiet =
        /^(?:_acpmux\/(?:watch|events|usage|session\/auth|harness\/health|models|harnesses)|session\/load)$/;
      proto.send = function (raw) {
        try {
          const method = JSON.parse(raw).method;
          if (method && !quiet.test(method)) counters.rpc.push(method);
        } catch {}
        return proto.__fujSend.call(this, raw);
      };
    }
    const native = await import("/src/agent-session/acpmux/native.ts");
    const { NativeError } = await import("/src/agent-session/acpmux/nativeError.ts");
    // The app's host answers these; here the call is noted and refused as a page with no app is.
    native.setNativeHost((method) => {
      counters.host.push(method);
      return Promise.reject(
        new NativeError({ code: "native.not_connected", origin: "native" }, "The app is not connected to this pane."),
      );
    });
  });
}

class Walk {
  constructor(cell, page, dir) {
    this.cell = cell;
    this.page = page;
    this.dir = dir;
    this.steps = [];
    this.reds = [];
    this.allowed = [];
    this.seen = new Set();
    this.n = 0;
    this.console = [];
    page.on("console", (message) => {
      if (message.type() === "error") this.console.push(message.text());
    });
    page.on("pageerror", (error) => this.console.push(`uncaught: ${error.message}`));
    page.on("response", (response) => {
      if (response.status() >= 400 && response.url().startsWith(base))
        this.console.push(`HTTP ${response.status()} for ${response.url().slice(base.length)}`);
    });
  }

  red(rule, where, step, detail, screenshot) {
    const key = `${rule}|${where}|${detail}`;
    if (this.seen.has(key)) return;
    this.seen.add(key);
    const allowed = ALLOWED.find((entry) => entry.rule === rule && detail.includes(entry.detail));
    if (allowed) {
      this.allowed.push({ rule, where, step, detail: scrub(detail), why: allowed.why });
      return;
    }
    this.reds.push({
      rule,
      where,
      step,
      detail: scrub(detail),
      ...(screenshot ? { screenshot } : {}),
    });
  }

  async shot(label) {
    this.n += 1;
    const file = `${String(this.n).padStart(3, "0")}-${label.replace(/[^a-z0-9]+/gi, "-").slice(0, 60)}.png`;
    await this.page.screenshot({
      path: path.join(this.dir, file),
      animations: "disabled",
      caret: "hide",
    });
    return path.relative(outRoot, path.join(this.dir, file));
  }

  /// One step: its screenshot, and every rule's verdict (`pass`, `red`, or `n/a` where it does not apply).
  async step(where, step, found, applies) {
    const screenshot = await this.shot(`${where}-${step}`);
    const consoleReds = await this.page
      .evaluate((messages) => window.__fuj?.consoleErrors(messages) ?? [], this.console.splice(0))
      .catch(() => []);
    const reds = [...found, ...consoleReds];
    const verdicts = Object.fromEntries(
      RULES.map((rule) => [
        rule,
        reds.some((red) => red.rule === rule)
          ? "red"
          : applies.includes(rule) || rule === "console-error"
            ? "pass"
            : "n/a",
      ]),
    );
    this.steps.push({
      where,
      step,
      screenshot,
      verdicts,
      reds: reds.map((red) => ({ ...red, detail: scrub(red.detail) })),
    });
    for (const red of reds) this.red(red.rule, where, step, red.detail, screenshot);
  }

  result(ms) {
    fs.writeFileSync(path.join(this.dir, "steps.json"), JSON.stringify(this.steps, null, 2));
    return {
      cell: this.cell.id,
      harness: this.cell.harness,
      state: this.cell.state,
      outcome: this.reds.length ? "red" : "pass",
      // The controls clicked (each surface's first paint is a step of its own in steps.json, not here).
      steps: this.steps.filter((step) => step.step !== "first paint").length,
      reds: this.reds,
      allowed: this.allowed,
      ms,
      walked: this.steps,
    };
  }
}

/// Loads the in-page checks (src/devkit/firstUserJourney/inpage.ts) through the dev server.
async function eyes(page) {
  // A page that reloads itself while loading (Settings' first open) drops the helpers: load them again.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await page.waitForLoadState("load").catch(() => undefined);
    const ready = await page
      .evaluate(async () => {
        window.__fuj = await import("/src/devkit/firstUserJourney/inpage.ts");
        await new Promise((resolve) => setTimeout(resolve, 250));
        return !!window.__fuj;
      })
      .catch(() => false);
    if (ready) return;
  }
  throw new Error("the page kept reloading; the journey helpers could not load");
}

/// A surface's first paint: errors, raw codes, disabled controls, spinners that never end, and layout at
/// both sizes. Then each control it shows, clicked in turn, judged by what the click changed.
async function surface(walk, where, open, options = {}) {
  // One surface that cannot be walked (it never opened, the runner lost it) is a red of its own;
  // the cell's other surfaces still run.
  try {
    await walkSurface(walk, where, open, options);
  } catch (error) {
    const shot = await walk.shot(`${where}-stopped`).catch(() => undefined);
    walk.red("crash", where, "open", `the walk stopped: ${String(error?.message ?? error).split("\n")[0]}`, shot);
  }
}

async function walkSurface(walk, where, open, { scope, each = "click", reopenEach = false, after } = {}) {
  const { page } = walk;
  const opened = Date.now();
  await open();
  await eyes(page);
  await settle(page);
  const first = [...(await page.evaluate((ignore) => window.__fuj.check(ignore), MOCK_ARTIFACTS))];
  // A loading indicator gets the rest of its ten seconds before it counts.
  let loading = await page.evaluate(() => window.__fuj.loading());
  if (loading.length) {
    await page.waitForTimeout(Math.max(0, SPINNER_GRACE_MS - (Date.now() - opened)));
    loading = await page.evaluate(() => window.__fuj.loading());
    first.push(
      ...loading.map((what) => ({
        rule: "permanent-spinner",
        detail: `still loading after 10 s: ${what}`,
      })),
    );
  }
  first.push(...(await page.evaluate(() => window.__fuj.layout())));
  await page.setViewportSize(SMALL);
  await settle(page);
  const small = await page.evaluate(() => window.__fuj.layout());
  const smallShot = await walk.shot(`${where}-800x600`);
  await page.setViewportSize(VIEWPORT);
  await settle(page);
  await walk.step(
    where,
    "first paint",
    [...first, ...small.map((red) => ({ ...red, detail: `${red.detail} (${smallShot})` }))],
    ["error-without-next-step", "raw-error-code", "permanent-spinner", "layout-break", "dead-button"],
  );
  if (after) await after();
  const listed = (await page.evaluate((scope) => window.__fuj.controls(scope), scope)).filter(
    (control) => !control.disabled,
  );
  const todo = listed.slice(0, maxControls);
  if (listed.length > todo.length)
    console.log(`${walk.cell.id} ${where}: ${listed.length} controls, clicking the first ${todo.length}`);
  for (const control of todo) {
    if (reopenEach) {
      await open();
      await eyes(page);
      await settle(page);
    }
    let found = await page
      .evaluate(({ key, scope }) => window.__fuj?.mark(key, scope) ?? false, {
        key: control.key,
        scope,
      })
      .catch(() => false);
    if (!found) {
      await open();
      await eyes(page);
      await settle(page);
      found = await page.evaluate(({ key, scope }) => window.__fuj.mark(key, scope), {
        key: control.key,
        scope,
      });
      if (!found) continue;
    }
    const before = await page.evaluate(() => window.__fuj.snapshot());
    const clicked = await page.evaluate(() => window.__fuj.targetPath());
    const target = page.locator("[data-fuj-target]").first();
    let clickError;
    try {
      if (each === "click")
        await target.click({ timeout: 3_000 }).catch(async (error) => {
          // A control a hover reveals (a message's actions): a person points at its row first.
          for (const up of ["..", "../..", "../../..", "../../../..", "../../../../.."].map(
            (path) => `xpath=${path}`,
          )) {
            await target
              .locator(up)
              .hover({ timeout: 1_000 })
              .catch(() => undefined);
            if (
              await target.click({ timeout: 1_000 }).then(
                () => true,
                () => false,
              )
            )
              return;
          }
          throw error;
        });
    } catch (error) {
      clickError = String(error?.message ?? error).split("\n")[0];
    }
    await page.waitForTimeout(500);
    await settle(page).catch(() => undefined);
    const reds = [];
    const alive = await page.evaluate(() => !!window.__fuj).catch(() => false);
    if (!alive) {
      // The click left the page (a link, a reload): that is an effect; the next control reopens it.
      await walk.step(where, `click "${control.label}"`, [], ["dead-button"]);
      continue;
    }
    const effect = await page.evaluate(({ before, clicked }) => window.__fuj.effect(before, clicked), {
      before,
      clicked,
    });
    if (clickError && !effect.dom && !effect.url) {
      // Playwright could not click it (covered, moved away): a person could not either.
      reds.push({
        rule: "dead-button",
        detail: `"${control.label}" could not be clicked: ${clickError.slice(0, 120)}`,
      });
    } else {
      reds.push(
        ...(await page.evaluate(({ label, effect, selected }) => window.__fuj.deadButton(label, effect, selected), {
          label: control.label,
          effect,
          selected: control.selected,
        })),
      );
    }
    if (await page.evaluate(() => window.__fuj.blank()))
      reds.push({ rule: "crash", detail: `the page went blank after "${control.label}"` });
    reds.push(
      ...(await page.evaluate((ignore) => window.__fuj.check(ignore), MOCK_ARTIFACTS)).filter(
        (red) => red.rule !== "dead-button",
      ),
    );
    await walk.step(where, `click "${control.label}"`, reds, [
      "dead-button",
      "error-without-next-step",
      "raw-error-code",
      "crash",
    ]);
    if (reds.some((red) => red.rule === "crash")) {
      await open();
      await eyes(page);
      await settle(page);
      continue;
    }
    // Close what the click opened (a menu, a popover, a dialog) before the next control.
    await page.keyboard.press("Escape").catch(() => undefined);
    if (effect.url) {
      await open();
      await eyes(page);
      await settle(page);
    }
  }
}

async function harnessCell(walk, cell) {
  const { page } = walk;
  const journey = `${cell.harness}:${cell.state}`;
  await stubMockBridge(page, {
    globals: { cmuxAcpmuxMockJourney: { harness: cell.harness, state: cell.state } },
    ready: { newSession: true },
  });
  const paneURL = `${base}/agent-pane/?mock&journey=${encodeURIComponent(journey)}`;
  const openPane = async () => {
    await page.goto(paneURL, { waitUntil: "load", timeout: 120_000 });
    await page.waitForSelector('[contenteditable="true"], textarea', { timeout: 60_000 });
    await instrumentPane(page);
    await settle(page);
  };
  const pickerButton = () =>
    page
      .locator(".acpmux-picker-button")
      .filter({ hasText: /./ })
      .and(page.locator('[aria-label*="odel" i], [aria-label*="gent" i]'))
      .first();
  // With no harness installed the composer offers Add harness where the model button would be; it
  // opens the same choice (the Harnesses page). Either is the picker a first user meets.
  const PICKER = '[role="listbox"], [role="menu"], [role="dialog"], .acpmux-harnesses';
  const openPicker = async () => {
    await openPane();
    const button = (await pickerButton().count())
      ? pickerButton()
      : page.getByRole("button", { name: /model|agent|add harness/i }).first();
    await button.click({ timeout: 5_000 });
    await page.waitForSelector(PICKER, { timeout: 5_000 });
    await settle(page);
  };

  await surface(walk, "pane/new-chat", openPane);
  await surface(walk, "pane/picker", openPicker, { scope: PICKER, reopenEach: true });

  // The first prompt: the cell's harness picked in the picker, then sent.
  const sendFirst = async () => {
    await openPicker().catch(() => openPane());
    const name = await harnessName(page, cell.harness);
    const entry = page.locator(PICKER).getByText(name, { exact: false }).first();
    if (await entry.count()) await entry.click({ timeout: 3_000 }).catch(() => undefined);
    await page.keyboard.press("Escape").catch(() => undefined);
    const field = page.locator('[contenteditable="true"], textarea').first();
    await field.click();
    await page.keyboard.type("Can you look at this repo and tell me where to start?");
    await page.keyboard.press("Enter");
    // A reply, a failed turn, or a start error: whichever the cell gives, within fifteen seconds.
    await page
      .waitForFunction(
        () =>
          /Mock reply to/.test(document.body.innerText) ||
          document.querySelector('[class*="error" i], [class*="failure" i], [role="alert"]') !== null,
        null,
        { timeout: 15_000 },
      )
      .catch(() => undefined);
    await page.waitForTimeout(800);
  };
  await surface(walk, "pane/first-prompt", sendFirst, {
    scope: ".acpmux-scroll, [class*='notice' i], [role='alert']",
  });

  await surface(walk, "pane/harnesses", async () => {
    await openPane();
    await page.evaluate(() => window.cmuxAcpmuxBridge?.command("showHarnesses"));
    await page.waitForTimeout(600);
  });

  await surface(
    walk,
    "settings/agents",
    async () => {
      await page.goto(`${base}/settings/?mock&journey=${encodeURIComponent(journey)}`, {
        waitUntil: "load",
        timeout: 120_000,
      });
      await page.locator('[data-section-link="agents"]').first().click({ timeout: 10_000 });
      await page.waitForTimeout(500);
    },
    { scope: "main, [role='main'], .settings-content, .content" },
  );
}

async function harnessName(page, harness) {
  return page.evaluate(async (harness) => {
    const catalog = await import("/src/agent-session/acpmux/modelCatalogData.ts");
    const brands = await import("/src/agent-session/shared/agentBrands.generated.ts").catch(() => ({}));
    const fromCatalog = catalog.BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === harness)?.name;
    const fromBrands = (brands.SUPPORTED_AGENTS ?? []).find?.((entry) => entry.id === harness)?.name;
    return fromCatalog ?? fromBrands ?? harness;
  }, harness);
}

async function pagesCell(walk, cell) {
  const { page } = walk;
  const url = `${base}/${cell.page}/?mock`;
  const open = async () => {
    await page.goto(url, { waitUntil: "load", timeout: 120_000 });
    await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => undefined);
  };
  if (cell.page !== "settings") {
    await surface(walk, cell.page, open);
    return;
  }
  // Settings: every section, each its own surface.
  await open();
  const sections = await page.$$eval("[data-section-link]", (links) =>
    links.map((link) => link.getAttribute("data-section-link")),
  );
  for (const section of sections) {
    await surface(
      walk,
      `settings/${section}`,
      async () => {
        await open();
        await page.locator(`[data-section-link="${section}"]`).first().click({ timeout: 10_000 });
        await page.waitForTimeout(400);
      },
      { scope: "main, [role='main'], .settings-content, .content" },
    );
  }
}

/// Paths and machine-specific bits out of a red's text, and no longer than the schema allows.
function scrub(text) {
  return String(text)
    .replaceAll(os.homedir(), "~")
    .replace(/https?:\/\/127\.0\.0\.1:\d+/g, "")
    .replace(/\s+/g, " ")
    .slice(0, 200);
}

function write(results, harnesses) {
  let build = process.env.GITHUB_SHA ?? null;
  try {
    build ??= execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: webviews,
      encoding: "utf8",
    }).trim();
  } catch {}
  const runURL =
    process.env.GITHUB_RUN_ID && process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
      : null;
  const doc = {
    schema: 1,
    surface: "web",
    generated_at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    build: build ?? "unknown",
    run_url: runURL,
    cells: results.map(({ cell, harness, state, outcome, steps, reds }) => ({
      cell,
      harness,
      state,
      outcome,
      steps,
      reds,
    })),
    // The mock serves every state: no cell waits on a real account.
    missing_accounts: [],
  };
  fs.writeFileSync(path.join(outRoot, "results.json"), `${JSON.stringify(doc, null, 2)}\n`);
  fs.writeFileSync(
    path.join(outRoot, "steps.json"),
    `${JSON.stringify(
      results.map(({ cell, walked, allowed }) => ({ cell, allowed, steps: walked })),
      null,
      2,
    )}\n`,
  );
  fs.writeFileSync(
    path.join(outRoot, "summary.md"),
    summary(
      doc,
      harnesses,
      results.flatMap((result) => result.allowed),
    ),
  );
  console.log(`wrote ${path.join(outRoot, "results.json")} and summary.md`);
}

function summary(doc, harnesses, allowed) {
  const byId = new Map(doc.cells.map((cell) => [cell.cell, cell]));
  const verdict = (cell) =>
    !cell ? "–" : cell.outcome === "pass" ? `pass (${cell.steps})` : `**red ${cell.reds.length}** (${cell.steps})`;
  const lines = [
    "# First-user journey (web)",
    "",
    `Build ${doc.build}, ${doc.generated_at}${doc.run_url ? `, [run](${doc.run_url})` : ""}. Each cell: steps walked, and reds when any.`,
    "",
    `| harness | ${STATES.join(" | ")} |`,
    `| --- | ${STATES.map(() => "---").join(" | ")} |`,
  ];
  for (const harness of harnesses) {
    if (!STATES.some((state) => byId.has(`${harness}/${state}`))) continue;
    lines.push(`| ${harness} | ${STATES.map((state) => verdict(byId.get(`${harness}/${state}`))).join(" | ")} |`);
  }
  const pageCells = doc.cells.filter((cell) => cell.harness === null);
  if (pageCells.length) {
    lines.push("", "| page | verdict |", "| --- | --- |");
    for (const cell of pageCells) lines.push(`| ${cell.cell.replace(/^pages\//, "")} | ${verdict(cell)} |`);
  }
  const all = doc.cells.flatMap((cell) => cell.reds.map((red) => ({ ...red, cell: cell.cell })));
  const pass = doc.cells.filter((cell) => cell.outcome === "pass").length;
  lines.push("", `${pass} of ${doc.cells.length} cells pass; ${all.length} reds.`, "", "## Reds by rule");
  for (const rule of RULES) {
    const reds = all.filter((red) => red.rule === rule);
    if (!reds.length) continue;
    // One line per distinct finding, with the cells it shows in.
    const groups = new Map();
    for (const red of reds) {
      const key = `${red.where} | ${red.detail.replace(/\(cells\/[^)]*\)/, "")}`;
      const group = groups.get(key) ?? { red, cells: [] };
      group.cells.push(red.cell);
      groups.set(key, group);
    }
    lines.push("", `### ${rule} (${reds.length} in ${groups.size} distinct)`, "");
    for (const { red, cells } of groups.values()) {
      const shown =
        cells.length > 4 ? `${cells.slice(0, 4).join(", ")} and ${cells.length - 4} more` : cells.join(", ");
      lines.push(
        `- ${red.where}, ${red.step}: ${red.detail}${red.screenshot ? ` ([shot](${red.screenshot}))` : ""}. Cells: ${shown}`,
      );
    }
  }
  if (allowed.length) {
    lines.push("", "## Allowed (settled designs, not reds)", "");
    const seen = new Set();
    for (const entry of allowed) {
      if (seen.has(entry.detail)) continue;
      seen.add(entry.detail);
      lines.push(`- ${entry.where}: ${entry.detail}. Why: ${entry.why}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

// Module-level so the walk's helpers reach them; set by main().
let server;
let base;
let browser;
await main();

async function main() {
  const started = Date.now();
  server = await startDevServer("vite.config.ts");
  base = server.url.replace(/\/$/, "");
  browser = await launchBrowser();
  let failed = false;
  try {
    const { harnesses, pages } = await discover();
    const cells = [
      ...harnesses.flatMap((harness) => STATES.map((state) => ({ id: `${harness}/${state}`, harness, state }))),
      ...pages.map((page) => ({ id: `pages/${page}`, harness: null, state: null, page })),
    ].filter((cell) => !only.length || only.some((want) => cell.id === want || cell.id.startsWith(`${want}/`)));
    console.log(`first-user journey: ${cells.length} cells, ${workers} at once, out ${outRoot}`);
    const results = [];
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(workers, cells.length) }, async () => {
        while (next < cells.length) {
          const cell = cells[next++];
          const result = await runCell(cell);
          results.push(result);
          console.log(
            `${result.cell}: ${result.outcome} (${result.steps} steps, ${result.reds.length} reds, ${Math.round(result.ms / 1000)}s)`,
          );
        }
      }),
    );
    results.sort((a, b) => cells.findIndex((c) => c.id === a.cell) - cells.findIndex((c) => c.id === b.cell));
    write(results, harnesses);
  } catch (error) {
    failed = true;
    console.error(error);
  } finally {
    await browser.close();
    await server.close();
  }
  console.log(`done in ${Math.round((Date.now() - started) / 1000)}s`);
  process.exit(failed ? 1 : 0);
}
