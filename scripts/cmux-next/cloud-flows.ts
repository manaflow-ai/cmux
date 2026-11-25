#!/usr/bin/env bun
/**
 * Flows: repeatable onboarding and interaction paths, one JSON file each (scripts/cmux-next/flows/), run the same way
 * in CI and by hand against a Cloud backend, each with a video and a per-step log.
 *
 *   bun scripts/cmux-next/cloud-flows.ts --flow scripts/cmux-next/flows/github-connect.json --backend staging --out DIR
 *   bun scripts/cmux-next/cloud-flows.ts --flow FILE --check          (reads the file, runs nothing)
 *
 * Leo (2026-11-20): "those steps, we ought to be able to make it more repeatable. a la ci. all these things. they
 * will be useful for testing out onboarding flows and interaction flows". Doc:
 * docs/cmux-next/cloud-github-main-path-recording.md.
 *
 * A flow file is { name, title, vars, steps: [{ id, title, do, needs?, cleanup?, ...params }] }. `do` names one of
 * the step kinds below (KINDS); a new flow is a new file, and a new kind of step one function here. Each step runs
 * as a cloud-journey.ts Journey step (the same PASS/FAIL/SKIP log, journey.json and summary.md), and the journey
 * itself is a step kind (`journey`), so everything cloud-journey.ts checks is a flow step too.
 *
 * `needs` names what a step needs from the environment (NEEDS): the staging account, the GitHub test user, a Claude
 * login. A step whose needs are absent is skipped with the named reason ("needs GitHub test user: secrets absent
 * (...)"), and so is every later step that needs it, so a run without those secrets still runs every step that needs
 * no account and passes with skips. After a failed step the rest are skipped, except `cleanup` steps, which always
 * run. Exit 0 when no step failed.
 *
 * Browser steps run in one headless Chromium (Playwright, the repository's pin in scripts/gallery-matrix) that records
 * DIR/flow.webm, and each takes a screenshot (DIR/NN-id.png). Secrets come from the environment only; none is
 * printed or put in a step's detail (Journey scrubs every value in its `secrets`). The TOTP code is made here
 * (RFC 6238) and its field is drawn as dots, so no frame shows it.
 */
import { spawnSync } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Api, http, Journey, passwordSignIn, resolveBackend, STACK, type Backend } from "./cloud-journey.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");

/** What a step can need, and the environment that provides it. */
export const NEEDS: Record<string, { label: string; env: string[] }> = {
  "staging-account": { label: "staging account", env: ["CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"] },
  "github-test-user": { label: "GitHub test user", env: ["CMUX_GITHUB_TEST_LOGIN", "CMUX_GITHUB_TEST_PASSWORD", "CMUX_GITHUB_TEST_TOTP_SEED"] },
  "claude-login": { label: "Claude login", env: ["CLAUDE_CODE_OAUTH_TOKEN"] },
};

export type FlowStep = { id: string; title: string; do: string; needs?: string[]; cleanup?: boolean; [param: string]: unknown };
export type Flow = { name: string; title: string; vars?: Record<string, string>; steps: FlowStep[] };

export function readFlow(file: string): Flow {
  const flow = JSON.parse(readFileSync(file, "utf8")) as Flow;
  if (!flow.name || !Array.isArray(flow.steps) || flow.steps.length === 0) throw new Error(`${file}: a flow needs a name and steps`);
  const ids = new Set<string>();
  for (const s of flow.steps) {
    if (!s.id || !s.title || !s.do) throw new Error(`${file}: every step needs id, title and do`);
    if (ids.has(s.id)) throw new Error(`${file}: step id ${s.id} twice`);
    ids.add(s.id);
    if (!(s.do in KINDS)) throw new Error(`${file}: step ${s.id}: unknown kind ${s.do} (one of ${Object.keys(KINDS).join(", ")})`);
    for (const n of s.needs ?? []) if (!(n in NEEDS)) throw new Error(`${file}: step ${s.id}: unknown need ${n}`);
  }
  return flow;
}

/** The named reason a step cannot run here, or null. */
export function missingNeed(step: FlowStep, env: Record<string, string | undefined>): string | null {
  for (const n of step.needs ?? []) {
    const absent = NEEDS[n].env.filter((k) => !env[k]);
    if (absent.length) return `needs ${NEEDS[n].label}: secrets absent (${absent.join(", ")})`;
  }
  return null;
}

/** RFC 6238 TOTP: six digits, 30 s, SHA-1 (GitHub's authenticator setup). */
export function totp(seed: string, at = Date.now()): string {
  const clean = seed.replace(/[\s=]/g, "").toUpperCase();
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of clean) {
    const v = alphabet.indexOf(c);
    if (v < 0) throw new Error("the TOTP seed is not base32");
    bits += v.toString(2).padStart(5, "0");
  }
  const key = Buffer.from((bits.match(/.{8}/g) ?? []).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 1000 / 30)));
  const digest = createHmac("sha1", key).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  return String((digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

/** `{name}` in a step's text from the flow's vars. */
export function fill(text: string, vars: Record<string, string>): string {
  return text.replace(/\{([a-z_]+)\}/g, (m, k: string) => vars[k] ?? m);
}

type Ctx = {
  flow: Flow;
  backend: Backend;
  out: string;
  vars: Record<string, string>;
  api: Api;
  J: Journey;
  env: Record<string, string | undefined>;
  page?: any;
  browserClose?: () => Promise<void>;
  actions: number;
};
type Result = { value: null; detail: string };
const done = (detail: string): Result => ({ value: null, detail });

// ---- the browser (Playwright from the repository's own pin) ----
function playwright(): any {
  const require = createRequire(import.meta.url);
  // The pin first: a bare "playwright" can resolve to another version (bun's global cache) whose Chromium and ffmpeg
  // builds `playwright install` in scripts/gallery-matrix did not fetch.
  for (const where of [path.join(ROOT, "scripts/gallery-matrix/node_modules/playwright"), path.join(ROOT, "webviews/node_modules/playwright"), "playwright"]) {
    try {
      return require(where);
    } catch {
      // the next place
    }
  }
  throw new Error("Playwright is not installed: (cd scripts/gallery-matrix && bun install --frozen-lockfile && bunx playwright install chromium)");
}

async function page(ctx: Ctx): Promise<any> {
  if (ctx.page) return ctx.page;
  const { chromium } = playwright();
  const launch = async () => {
    try {
      return await chromium.launch({ headless: true });
    } catch {
      return await chromium.launch({ headless: true, channel: "chrome" });
    }
  };
  const browser = await launch();
  const viewport = { width: 1280, height: 800 };
  let context = await browser.newContext({ viewport, recordVideo: { dir: path.join(ctx.out, "video"), size: viewport } });
  try {
    ctx.page = await context.newPage();
  } catch (error) {
    // No Playwright ffmpeg (`playwright install ffmpeg`): the steps still run, with stills and no video.
    if (!/ffmpeg/i.test(String((error as Error)?.message ?? error))) throw error;
    console.log("::warning::no Playwright ffmpeg, so no video; install it with `bunx playwright install ffmpeg`");
    await context.close().catch(() => undefined);
    context = await browser.newContext({ viewport });
    ctx.page = await context.newPage();
  }
  ctx.page.setDefaultTimeout(20_000);
  ctx.browserClose = async () => {
    await context.close();
    await browser.close();
    const made = existsSync(path.join(ctx.out, "video")) ? readdirSync(path.join(ctx.out, "video")).filter((f) => f.endsWith(".webm")) : [];
    if (made[0]) renameSync(path.join(ctx.out, "video", made[0]), path.join(ctx.out, "flow.webm"));
  };
  return ctx.page;
}

async function shot(ctx: Ctx, step: FlowStep): Promise<void> {
  if (!ctx.page) return;
  const n = String(ctx.J.steps.length + 1).padStart(2, "0");
  await ctx.page.screenshot({ path: path.join(ctx.out, `${n}-${step.id}.png`) }).catch(() => undefined);
}

/** Click the first element of ROLE (or any clickable) whose name matches PATTERN; false when none shows. */
async function clickNamed(ctx: Ctx, pattern: RegExp, roles = ["button", "link", "radio", "menuitemcheckbox", "option", "checkbox"]): Promise<boolean> {
  for (const role of roles) {
    const hit = ctx.page.getByRole(role, { name: pattern }).first();
    if (await hit.isVisible().catch(() => false)) {
      await hit.click();
      ctx.actions++;
      return true;
    }
  }
  return false;
}

async function type(ctx: Ctx, selector: string, text: string): Promise<boolean> {
  const field = ctx.page.locator(selector).first();
  if (!(await field.isVisible().catch(() => false))) return false;
  await field.fill(text);
  ctx.actions++;
  return true;
}

/** Which GitHub page shows, by its URL. */
export function githubPage(url: string): string {
  if (url.includes("/sessions/verified-device")) return "device";
  if (url.includes("/login/oauth/authorize")) return "authorize";
  if (url.includes("/sessions/two-factor")) return "2fa";
  if (/github\.com\/(login|session)(\?|$|\/?$)/.test(url)) return "login";
  if (url.includes("/sudo")) return "sudo";
  if (url.includes("/installations/new/permissions") || /\/settings\/installations\/\d+/.test(url)) return "permissions";
  if (url.includes("/installations/new")) return "install";
  return url.includes("github.com") ? "other" : "left";
}

// ---- the step kinds ----
const KINDS: Record<string, (ctx: Ctx, step: FlowStep) => Promise<Result>> = {
  /** The staging account's Stack sign-in; the API calls after it are that person's. */
  "sign-in": async (ctx) => {
    const s = await passwordSignIn(STACK[ctx.backend.stack], ctx.env.CMUX_DOGFOOD_STACK_EMAIL!, ctx.env.CMUX_DOGFOOD_STACK_PASSWORD!);
    ctx.J.secrets.push(s.access, s.refresh);
    ctx.api.bearer = s.access;
    return done(`signed in on ${ctx.backend.name} (${ctx.backend.api})`);
  },

  /** GET /v1/integrations/github/status: the App configured, and the one `slug` names. */
  "github-config": async (ctx) => {
    const r = await ctx.api.raw("GET", "/v1/integrations/github/status", undefined, 20_000);
    if (r.status !== 200) throw new Error(`GET /v1/integrations/github/status: HTTP ${r.status}`);
    const slug = r.body?.app_slug ?? null;
    ctx.vars.app_slug = typeof slug === "string" ? slug : "";
    const detail = `configured ${r.body?.configured === true}, app_slug ${JSON.stringify(slug)}, connection ${r.body?.connection?.status ?? "none"}`;
    // `slug` pins one App; unset, the slug the API names (read from GitHub's GET /app, so a renamed App passes) is used.
    const want = ctx.vars.slug ?? "";
    if (r.body?.configured !== true || typeof slug !== "string" || !slug.trim() || (want && slug !== want)) throw new Error(`${detail}; want configured true and app_slug ${want ? `"${want}"` : "named"} (the staging API's GitHub App setting)`);
    if (!want) ctx.vars.slug = slug;
    return done(detail);
  },

  /** https://api.github.com/apps/<slug> answers 200: a public App, which an org its owner does not own can install. */
  "github-app-public": async (ctx) => {
    const slug = ctx.vars.app_slug || ctx.vars.slug;
    const r = await http("GET", `https://api.github.com/apps/${slug}`, undefined, { accept: "application/vnd.github+json", "user-agent": "cmux-flows" }, 20_000);
    if (r.status === 200) return done(`https://api.github.com/apps/${slug} answers 200 (owner ${r.body?.owner?.login ?? "?"})`);
    throw new Error(`https://api.github.com/apps/${slug} answers HTTP ${r.status}: ${r.status === 404 ? "the App is private (or the slug is wrong), so the test org cannot install it; make it public (the App's settings > Advanced > Make public)" : "retry"}`);
  },

  /** A new user: the team's GitHub connections to the test org are revoked first (only those). */
  "github-reset": async (ctx) => {
    const list = await ctx.api.read("integration.list", {});
    const rows: any[] = (list?.connections ?? []).filter((c: any) => c?.provider === "github" && !["revoked", "expired"].includes(c?.status));
    const ours = rows.filter((c) => String(c?.account ?? c?.account_login ?? "").toLowerCase() === ctx.vars.org.toLowerCase() || c?.status === "pending");
    for (const c of ours) await ctx.api.op("integration.revoke", { connection: c.id }, randomUUID());
    return done(`${rows.length} GitHub connection(s) on the team; revoked ${ours.length} (the test org's and pending ones)`);
  },

  /** Connect GitHub as the app does (integration.connect): GitHub's install page for the staging App. */
  "github-connect": async (ctx) => {
    const key = randomUUID();
    let value: any;
    try {
      value = await ctx.api.op("integration.connect", { provider: "github", return_to: `${ctx.vars.return_scheme}://integration/complete` }, key);
    } catch {
      // An API from before the completion link refuses return_to: the console finishes it (as the app falls back).
      value = await ctx.api.op("integration.connect", { provider: "github" }, `${key}:plain`);
    }
    const url = String(value?.authorize_url ?? "");
    if (!/^https:\/\/github\.com\//.test(url)) throw new Error(`integration.connect answered no GitHub URL (${url.slice(0, 60)})`);
    ctx.vars.authorize_url = url;
    ctx.vars.connection = String(value?.connection?.id ?? "");
    const p = await page(ctx);
    // GitHub's redirect back names the app's completion link; keep it (the app finishes it with its own sign-in).
    p.on("response", (r: any) => {
      const where = r.headers()?.location ?? "";
      if (/:\/\/integration\/complete\?/.test(where)) ctx.vars.completion = where;
    });
    p.on("framenavigated", (f: any) => {
      if (/:\/\/integration\/complete\?/.test(f.url())) ctx.vars.completion = f.url();
    });
    await p.goto(url);
    ctx.actions++;
    await p.waitForLoadState("domcontentloaded");
    return done(`GitHub's page opened: ${githubPage(p.url())} (${new URL(p.url()).pathname})`);
  },

  /** GitHub's sign-in as the test user: password, then the TOTP code; a device check fails with its name. */
  "github-sign-in": async (ctx) => {
    const p = ctx.page;
    for (let round = 0; round < 6; round++) {
      const at = githubPage(p.url());
      if (at === "login") {
        if (!(await type(ctx, "#login_field", ctx.env.CMUX_GITHUB_TEST_LOGIN!)) || !(await type(ctx, "#password", ctx.env.CMUX_GITHUB_TEST_PASSWORD!))) throw new Error("GitHub's sign-in form did not show its fields");
        await p.locator("input[type=submit][name=commit], button[type=submit]").first().click();
        ctx.actions++;
      } else if (at === "2fa") {
        await p.addStyleTag({ content: "input { -webkit-text-security: disc !important; }" }); // no frame shows the code
        if (Date.now() / 1000 % 30 > 25) await Bun.sleep(6_000); // a fresh window, not one about to turn
        const code = totp(ctx.env.CMUX_GITHUB_TEST_TOTP_SEED!);
        ctx.J.secrets.push(code);
        const typed = (await type(ctx, "#app_totp", code)) || (await type(ctx, "#otp", code)) || (await type(ctx, "input[name=app_otp]", code));
        if (!typed) throw new Error("GitHub's two-factor page has no authenticator code field (another method is the default: see the doc)");
        await clickNamed(ctx, /^verify/i, ["button"]);
      } else if (at === "device") {
        throw new Error("GitHub asked to verify a new device (an emailed code): turn on TOTP 2FA for the test user (see the doc)");
      } else {
        return done(`signed in as the test user; GitHub shows ${at} (${new URL(p.url()).pathname})`);
      }
      await p.waitForLoadState("domcontentloaded").catch(() => undefined);
      await Bun.sleep(1_500);
    }
    throw new Error(`GitHub's sign-in did not finish (last page ${new URL(p.url()).pathname})`);
  },

  /** The App's install: the org, only the one repository, Install (and Authorize, Confirm access when asked). */
  "github-install": async (ctx) => {
    const p = ctx.page;
    const org = ctx.vars.org, repo = ctx.vars.repo;
    let pressed = false;
    for (let round = 0; round < 12; round++) {
      const at = githubPage(p.url());
      if (at === "install") {
        if (!(await clickNamed(ctx, new RegExp(`\\b${org}\\b`, "i"), ["link", "button"]))) throw new Error(`GitHub's install page lists no ${org} (the App is private, or the test user owns no such org)`);
      } else if (at === "permissions" && !pressed) {
        if (!(await clickNamed(ctx, /only select repositories/i, ["radio"]))) await p.getByText(/only select repositories/i).first().click();
        await clickNamed(ctx, /select repositories/i, ["button"]);
        const filter = p.getByPlaceholder(/search for a repository|find a repository/i).first();
        if (await filter.isVisible().catch(() => false)) {
          await filter.fill(repo);
          ctx.actions++;
          await Bun.sleep(1_500);
        }
        if (!(await clickNamed(ctx, new RegExp(`(^|/)${repo}$`, "i"), ["menuitemcheckbox", "option", "checkbox", "button"]))) throw new Error(`the repository picker offers no ${repo}`);
        await p.keyboard.press("Escape").catch(() => undefined);
        if (!(await clickNamed(ctx, /^(install|save)\b/i, ["button"]))) throw new Error("GitHub's page has no Install (or Save) button");
        pressed = true;
      } else if (at === "authorize") {
        if (!(await clickNamed(ctx, /^authorize/i, ["button"]))) throw new Error("GitHub's Authorize page has no Authorize button");
      } else if (at === "sudo") {
        await type(ctx, "#sudo_password", ctx.env.CMUX_GITHUB_TEST_PASSWORD!);
        await clickNamed(ctx, /^confirm/i, ["button"]);
      } else if (at === "left" || (pressed && (at === "other" || at === "permissions")) || ctx.vars.completion) {
        if (!pressed && !ctx.vars.completion) throw new Error(`the page left GitHub before Install (${new URL(p.url()).host})`);
        return done(`installed ${ctx.vars.app_slug || ctx.vars.slug} on ${org} for ${repo} only; GitHub returned ${ctx.vars.completion ? "the app's completion link" : `to ${new URL(p.url()).host}`}`);
      }
      await p.waitForLoadState("domcontentloaded").catch(() => undefined);
      await Bun.sleep(2_000);
    }
    throw new Error(`GitHub's install did not finish (last page ${new URL(p.url()).pathname})`);
  },

  /** What the app does with the completion link GitHub returned: integration.complete with its own sign-in. */
  "github-complete": async (ctx) => {
    if (!ctx.vars.completion) return done("no completion link came back (the console finished the connection itself)");
    const q = new URL(ctx.vars.completion.replace(/^[a-z0-9+.-]+:\/\//i, "https://")).searchParams;
    const params: Record<string, string> = {};
    for (const k of ["state", "code", "installation_id", "setup_action"]) if (q.get(k)) params[k] = q.get(k)!;
    if (q.get("error")) throw new Error(`GitHub returned error ${q.get("error")}`);
    // In the team the signed state names (x-cmux-team), as the app sends it; the API checks it against the session.
    let team: string | undefined;
    try {
      team = JSON.parse(Buffer.from(params.state.split(".")[1] ?? "", "base64url").toString("utf8"))?.team;
    } catch {
      team = undefined;
    }
    const api = new Api(ctx.backend.api, typeof team === "string" && /^team_[0-9a-f]{20}$/.test(team) ? team : ctx.api.team);
    api.bearer = ctx.api.bearer;
    await api.op("integration.complete", params, `complete:${params.state.slice(-40)}`);
    return done(`integration.complete answered ok (setup_action ${params.setup_action ?? "none"})`);
  },

  /** Back in cmux: the connection active and the repository listed (what Settings and the folder menu read). */
  "github-readback": async (ctx) => {
    const want = `${ctx.vars.org}/${ctx.vars.repo}`.toLowerCase();
    let last = "";
    for (const until = Date.now() + 120_000; Date.now() < until; await Bun.sleep(4_000)) {
      const s = await ctx.api.raw("GET", "/v1/integrations/github/status", undefined, 20_000);
      last = `status HTTP ${s.status}, connection ${s.body?.connection?.status ?? "none"}`;
      if (s.body?.connection?.status !== "active") continue;
      const r = await ctx.api.raw("GET", "/v1/integrations/github/repos", undefined, 20_000);
      const names: string[] = (r.body?.repos ?? []).map((x: any) => String(typeof x === "string" ? x : x?.full_name ?? "").toLowerCase());
      last += `, ${names.length} repo(s) listed`;
      if (names.includes(want)) return done(`connection active; ${names.length} repo(s) listed, ${want} among them`);
    }
    throw new Error(`within 120 s: ${last}`);
  },

  /** cloud-journey.ts as one step: its steps go in this flow's log (prefixed), the ones named in `expect` must pass. */
  journey: async (ctx, step) => {
    const dir = path.join(ctx.out, `journey-${step.id}`);
    mkdirSync(dir, { recursive: true });
    const args = ((step.args as string[]) ?? []).map((a) => fill(a, ctx.vars));
    const env: Record<string, string> = { ...(process.env as Record<string, string>) };
    for (const [k, v] of Object.entries((step.env as Record<string, string>) ?? {})) env[k] = fill(v, ctx.vars);
    const run = spawnSync("bun", [path.join(HERE, "cloud-journey.ts"), "--backend", ctx.backend.name, "--out", dir, ...args], { env, encoding: "utf8", timeout: Number(step.timeout_s ?? 1800) * 1000, maxBuffer: 64 << 20 });
    const steps: { step: string; status: string; ms: number; detail: string }[] = existsSync(path.join(dir, "journey.json")) ? JSON.parse(readFileSync(path.join(dir, "journey.json"), "utf8")).steps : [];
    for (const s of steps) ctx.J.record({ step: `  journey: ${s.step}`, status: s.status as any, ms: s.ms, detail: s.detail });
    for (const [name, pattern] of Object.entries((step.extract as Record<string, string>) ?? {})) {
      const m = steps.map((s) => new RegExp(pattern).exec(`${s.step} :: ${s.detail}`)).find(Boolean);
      if (m) ctx.vars[name] = m[1];
    }
    const want = (step.expect as string[]) ?? [];
    const notPassed = want.filter((w) => steps.find((s) => s.step === w)?.status !== "pass");
    if (run.status !== 0 || notPassed.length) {
      const failed = steps.filter((s) => s.status === "fail").map((s) => s.step);
      throw new Error(`journey exit ${run.status ?? run.signal}; failed: ${failed.join(", ") || "none"}; not passed of the expected: ${notPassed.join(", ") || "none"}`);
    }
    return done(`${steps.filter((s) => s.status === "pass").length} journey steps passed, ${steps.filter((s) => s.status === "skip").length} skipped`);
  },

  /** Open a page (a URL from the vars) and check it reads back: `expect_text` on the page, `expect_url` in its URL. */
  "browser-open": async (ctx, step) => {
    const p = await page(ctx);
    const url = fill(String(step.url), ctx.vars);
    if (/\{[a-z_]+\}/.test(url)) throw new Error(`no value for ${url}`);
    await p.goto(url);
    ctx.actions++;
    await p.waitForLoadState("domcontentloaded");
    if (step.expect_url && !new RegExp(fill(String(step.expect_url), ctx.vars)).test(p.url())) throw new Error(`the page is at ${p.url()}, not ${step.expect_url}`);
    if (step.expect_text) await p.getByText(new RegExp(fill(String(step.expect_text), ctx.vars), "i")).first().waitFor({ timeout: 20_000 });
    return done(`${new URL(p.url()).host}${new URL(p.url()).pathname}: ${(await p.title()).slice(0, 80)}`);
  },

  /** Uninstall the App from the test org again (cleanup, so the next run is a new user). */
  "github-uninstall": async (ctx) => {
    const p = await page(ctx);
    await p.goto(`https://github.com/organizations/${ctx.vars.org}/settings/installations`);
    const row = p.locator("li, .Box-row").filter({ hasText: new RegExp(ctx.vars.app_slug || ctx.vars.slug, "i") }).first();
    if (!(await row.isVisible().catch(() => false))) return done(`the App is not installed on ${ctx.vars.org}`);
    await row.getByRole("link", { name: /configure/i }).click();
    ctx.actions++;
    p.once("dialog", (d: any) => d.accept());
    if (!(await clickNamed(ctx, /^uninstall/i, ["button"]))) throw new Error("the installation page has no Uninstall button");
    await clickNamed(ctx, /^(i understand, )?uninstall/i, ["button"]).catch(() => false);
    await ctx.api.read("integration.list", {}).catch(() => undefined);
    return done(`uninstalled from ${ctx.vars.org}`);
  },
};

export async function runFlow(flow: Flow, backend: Backend, out: string, env: Record<string, string | undefined>): Promise<number> {
  mkdirSync(out, { recursive: true });
  const J = new Journey(backend, out, { flow: flow.name, title: flow.title });
  for (const k of Object.values(NEEDS).flatMap((n) => n.env)) if (env[k] && !k.endsWith("_LOGIN") && !k.endsWith("_EMAIL")) J.secrets.push(env[k]!);
  const vars: Record<string, string> = { tag: `fl-${Date.now().toString(36)}`, return_scheme: "cmux", ...(flow.vars ?? {}) };
  const ctx: Ctx = { flow, backend, out, vars, api: new Api(backend.api, env.CMUX_JOURNEY_TEAM || undefined), J, env, actions: 0 };
  let failed = false;
  const absent = new Set<string>();
  for (const step of flow.steps) {
    const title = `${step.id}: ${step.title}`;
    const why = missingNeed(step, env);
    if (why) {
      for (const n of step.needs ?? []) if (NEEDS[n].env.some((k) => !env[k])) absent.add(n);
      J.skip(title, why);
      continue;
    }
    if (failed && !step.cleanup) {
      J.skip(title, "an earlier step failed");
      continue;
    }
    const before = ctx.actions;
    // `warn_without: NEED`: a check that only matters once NEED is here (the App's public page matters to the install
    // only). Without NEED its failure is recorded as a skip that keeps the reason, never hidden and never a red.
    const warnNeed = typeof step.warn_without === "string" ? step.warn_without : "";
    if (warnNeed && NEEDS[warnNeed]?.env.some((k) => !env[k])) {
      const t0 = Date.now();
      try {
        const r = await KINDS[step.do](ctx, step);
        J.record({ step: title, status: "pass", ms: Date.now() - t0, detail: r.detail });
      } catch (error) {
        J.record({ step: title, status: "skip", ms: Date.now() - t0, detail: `not judged (needs ${NEEDS[warnNeed].label}: secrets absent); it would fail: ${String((error as Error)?.message ?? error)}` });
      }
      continue;
    }
    try {
      await J.step(title, async () => {
        const r = await KINDS[step.do](ctx, step);
        await shot(ctx, step);
        const n = ctx.actions - before;
        return { value: null, detail: n ? `${r.detail} [${n} click(s) or field(s)]` : r.detail };
      });
    } catch {
      await shot(ctx, step);
      failed = true; // a cleanup that failed leaves the next run no new user: a red too
    }
  }
  await ctx.browserClose?.().catch(() => undefined);
  const counts = (s: string) => J.steps.filter((x) => x.status === s && !x.step.startsWith("  ")).length;
  const line = `${failed ? "FAIL" : "PASS"} ${flow.name} on ${backend.name}: ${counts("pass")} passed, ${counts("fail")} failed, ${counts("skip")} skipped` +
    `${absent.size ? ` (skipped for absent secrets: ${[...absent].map((n) => NEEDS[n].label).join(", ")})` : ""}; video ${existsSync(path.join(out, "flow.webm")) ? "flow.webm" : ctx.browserClose ? "none (no Playwright ffmpeg)" : "none (no browser step ran)"}`;
  console.log(`\n${line}`);
  writeFileSync(path.join(out, "summary.md"), `${readFileSync(path.join(out, "summary.md"), "utf8")}\n${line}\n`);
  return failed ? 1 : 0;
}

function argValue(flag: string, argv: string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

async function main(argv = process.argv.slice(2)): Promise<number> {
  const file = argValue("--flow", argv);
  if (!file || argv.includes("--help")) {
    console.log("usage: cloud-flows.ts --flow FILE [--backend staging] [--out DIR] [--check]");
    return file ? 0 : 2;
  }
  const flow = readFlow(file);
  if (argv.includes("--check")) {
    for (const s of flow.steps) console.log(`${s.id.padEnd(18)} ${s.do.padEnd(18)} ${(s.needs ?? []).join(",").padEnd(36)} ${missingNeed(s, process.env) ?? "can run"}`);
    return 0;
  }
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging");
  const out = argValue("--out", argv) ?? path.join(process.env.RUNNER_TEMP ?? "/tmp", `flow-${flow.name}`);
  return runFlow(flow, backend, out, process.env);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
