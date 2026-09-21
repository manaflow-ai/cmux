/**
 * Compares a deployed IROH v2 Worker with this checkout.
 *
 * The shipped Mac app depends on directory rules (`src/rules.ts`). A production
 * Worker that predates a rule breaks clients built from main while every test
 * on main stays green (https://github.com/manaflow-ai/cmux/issues/13458). This
 * check reads the unauthenticated health route and fails when:
 *
 *   - the route is missing (the deployment predates it),
 *   - a rule this checkout implements is not advertised,
 *   - the deployment did not publish its source revision, or
 *   - the published revision is not an ancestor of the base ref.
 *
 * Being behind the base ref on other commits is reported, not failed.
 *
 * Usage: bun scripts/check-production-drift.ts [--url URL] [--base REF]
 * Environment: CMUX_IROH_V2_HEALTH_URL, CMUX_IROH_V2_DRIFT_BASE (default origin/main).
 */
import { HealthSchema } from "../src/health";
import { CONTROL_PLANE_RULES } from "../src/rules";

const PRODUCTION_HEALTH_URL = "https://cmux-iroh-v2.debussy.workers.dev/v2/health";
const DEPLOY_COMMAND = "cd workers/iroh-v2 && bun install --frozen-lockfile && CLOUDFLARE_ACCOUNT_ID=<account> bun run deploy:production";

function argument(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function git(...args: string[]): { ok: boolean; output: string } {
  const result = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  return { ok: result.exitCode === 0, output: new TextDecoder().decode(result.stdout).trim() };
}

const url = argument("--url") ?? process.env.CMUX_IROH_V2_HEALTH_URL ?? PRODUCTION_HEALTH_URL;
const base = argument("--base") ?? process.env.CMUX_IROH_V2_DRIFT_BASE ?? "origin/main";
const failures: string[] = [];
const notes: string[] = [];

let response: Response;
try {
  response = await fetch(url, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(15_000), redirect: "manual" });
} catch (error) {
  console.error(`::error::IROH v2 drift check could not reach ${url}: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(2);
}
const text = (await response.text()).slice(0, 64 * 1024);
if (response.status === 404) {
  failures.push(`${url} returned 404: the deployment predates the health route, so it also predates every rule in src/rules.ts. Deploy: ${DEPLOY_COMMAND}`);
} else if (!response.ok) {
  failures.push(`${url} returned HTTP ${response.status}`);
} else {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { parsed = undefined; }
  const health = HealthSchema.safeParse(parsed);
  if (!health.success) {
    failures.push(`${url} returned an unexpected payload; expected schemaId health.v1`);
  } else {
    const deployed = health.data;
    const missing = CONTROL_PLANE_RULES.filter(rule => !deployed.rules.includes(rule));
    const extra = deployed.rules.filter(rule => !CONTROL_PLANE_RULES.includes(rule));
    notes.push(`deployed environment=${deployed.environment} revision=${deployed.sourceRevision} rules=${deployed.rules.join(",") || "(none)"}`);
    if (missing.length) failures.push(`deployment does not implement: ${missing.join(", ")}. Clients on ${base} depend on them. Deploy: ${DEPLOY_COMMAND}`);
    if (extra.length) notes.push(`deployment advertises rules this checkout does not know: ${extra.join(", ")} (production is ahead of ${base})`);
    if (deployed.sourceRevision === "unknown") {
      failures.push("deployment did not publish its source revision; redeploy from a clean checkout with scripts/deploy-production.sh");
    } else if (!git("cat-file", "-e", `${deployed.sourceRevision}^{commit}`).ok) {
      failures.push(`deployed revision ${deployed.sourceRevision} is not in this checkout (fetch full history, or the deployment came from an unpushed tree)`);
    } else if (!git("merge-base", "--is-ancestor", deployed.sourceRevision, base).ok) {
      failures.push(`deployed revision ${deployed.sourceRevision} is not an ancestor of ${base}: production runs code that is not on ${base}`);
    } else {
      const pending = git("rev-list", "--count", `${deployed.sourceRevision}..${base}`, "--", "src");
      const count = Number(pending.output || "0");
      notes.push(count === 0
        ? `deployment matches ${base} for every Worker source commit`
        : `${count} Worker source commit(s) on ${base} are not deployed (rules are unaffected; deploy at the next release step)`);
      if (count > 0) console.log(`::warning::IROH v2 production is ${count} Worker source commit(s) behind ${base}`);
    }
  }
}

for (const note of notes) console.log(note);
for (const failure of failures) console.log(`::error::IROH v2 production drift: ${failure}`);
console.log(JSON.stringify({ url, base, ok: failures.length === 0, failures, notes }));
process.exit(failures.length ? 1 : 0);
