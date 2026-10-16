import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { join } from "node:path";
import { CONTROL_PLANE_RULES } from "../src/rules";

setDefaultTimeout(30_000);

// One canned health payload per request path; the script only sees an HTTP endpoint.
const responses = new Map<string, { status: number; body: unknown }>();
let server: ReturnType<typeof Bun.serve>;
// Inherited repository-selection variables must not redirect Git in the test or the checker.
const GIT_SELECTION_VARIABLES = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"];
const cleanEnvironment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !GIT_SELECTION_VARIABLES.includes(key)));
const head = new TextDecoder().decode(Bun.spawnSync(["git", "rev-parse", "HEAD"], { stdout: "pipe", env: cleanEnvironment }).stdout).trim();

beforeAll(() => {
  server = Bun.serve({
    port: 0, hostname: "127.0.0.1",
    fetch(request) {
      const canned = responses.get(new URL(request.url).pathname);
      if (!canned) return new Response("missing fixture", { status: 500 });
      return Response.json(canned.body, { status: canned.status });
    },
  });
});
afterAll(() => { server?.stop(true); });

async function run(path: string, canned: { status: number; body: unknown }) {
  responses.set(path, canned);
  // Asynchronous spawn: the in-process fixture server must keep serving while the script runs.
  const child = Bun.spawn(["bun", join(import.meta.dir, "../scripts/check-production-drift.ts"), "--url", `http://127.0.0.1:${server.port}${path}`, "--base", "HEAD"], {
    cwd: join(import.meta.dir, ".."), stdout: "pipe", stderr: "pipe", env: cleanEnvironment,
  });
  const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { exit, output: stdout + stderr };
}

const health = (overrides: Record<string, unknown> = {}) => ({
  schemaId: "health.v1", environment: "production", sourceRevision: head, rules: [...CONTROL_PLANE_RULES], ...overrides,
});

test("a deployment that predates the health route is drift", async () => {
  const result = await run("/predates", { status: 404, body: { schemaId: "error.v1", requestId: "unidentified", code: "unsupported_method", retryable: false } });
  expect(result.exit).toBe(1);
  expect(result.output).toContain("predates the health route");
});

test("a deployment missing a rule this checkout implements is drift", async () => {
  const result = await run("/missing-rule", { status: 200, body: health({ rules: [] }) });
  expect(result.exit).toBe(1);
  expect(result.output).toContain(`does not implement: ${CONTROL_PLANE_RULES.join(", ")}`);
});

test("a deployment without a published revision is drift", async () => {
  const result = await run("/unknown-revision", { status: 200, body: health({ sourceRevision: "unknown" }) });
  expect(result.exit).toBe(1);
  expect(result.output).toContain("did not publish its source revision");
});

test("a deployment from a revision that is not on the base ref is drift", async () => {
  const result = await run("/foreign-revision", { status: 200, body: health({ sourceRevision: "f".repeat(40) }) });
  expect(result.exit).toBe(1);
  expect(result.output).toContain("not in this checkout");
});

test("a health response from another environment is not the deployment being checked", async () => {
  const result = await run("/wrong-environment", { status: 200, body: health({ environment: "development" }) });
  expect(result.exit).toBe(1);
  expect(result.output).toContain("reports environment development, expected production");
});

test("a deployment at the base revision with every rule passes", async () => {
  const result = await run("/current", { status: 200, body: health() });
  expect(result.exit).toBe(0);
  expect(result.output).toContain("matches HEAD for every Worker source commit");
  expect(JSON.parse(result.output.trim().split("\n").at(-1)!)).toMatchObject({ ok: true, failures: [] });
});
