import { afterAll, afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { installVercelFirewallMock } from "./vercel-firewall-mock";

let readCache: () => Promise<unknown> = async () => undefined;
let writeCache: () => Promise<void> = async () => {};
const cacheGet = mock(async () => await readCache());
const cacheSet = mock(async () => await writeCache());
const contextSymbol = Symbol.for("@vercel/request-context");
const originalContext = Reflect.get(globalThis, contextSymbol);
Reflect.set(globalThis, contextSymbol, {
  get: () => ({ cache: { get: cacheGet, set: cacheSet } }),
});
installVercelFirewallMock();

const originalEnv = { ...process.env };
process.env.SKIP_ENV_VALIDATION = "1";
const { POST } = await import("../app/api/client-config/route");
const originalFetch = globalThis.fetch;
let timestamp = Date.now();
let clock: ReturnType<typeof spyOn<typeof Date, "now">>;
const config = { errorsWhileComputingFlags: false, featureFlags: { enabled: true }, featureFlagPayloads: {} };

beforeEach(() => {
  (process.env as Record<string, string>).NODE_ENV = "production";
  process.env.VERCEL = "1";
  process.env.VERCEL_ENV = "preview";
  process.env.VERCEL_DEPLOYMENT_ID = "cache-failure-test";
  process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cache-failure-test";
  timestamp += 60_000;
  clock = spyOn(Date, "now").mockImplementation(() => timestamp);
  readCache = async () => undefined;
  writeCache = async () => {};
  cacheGet.mockClear();
  cacheSet.mockClear();
  globalThis.fetch = mock(async () => Response.json(config)) as unknown as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  clock.mockRestore();
});

afterAll(() => {
  if (originalContext === undefined) Reflect.deleteProperty(globalThis, contextSymbol);
  else Reflect.set(globalThis, contextSymbol, originalContext);
  for (const key of ["NODE_ENV", "VERCEL", "VERCEL_ENV", "VERCEL_DEPLOYMENT_ID", "SKIP_ENV_VALIDATION", "CMUX_CLIENT_CONFIG_RATE_LIMIT_ID"]) {
    if (originalEnv[key] === undefined) delete process.env[key];
    else process.env[key] = originalEnv[key];
  }
});

function request(id = crypto.randomUUID()): Request {
  return new Request("https://cmux.test/api/client-config", {
    method: "POST",
    body: JSON.stringify({ distinctId: id }),
  });
}

test("cache read failures preserve a valid upstream response", async () => {
  readCache = async () => { throw new Error("cache unavailable"); };
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(config);
  expect(globalThis.fetch).toHaveBeenCalledTimes(1);
});

test("a stalled cache read has a bounded wait and resumes after the cooldown", async () => {
  let settle!: (value: unknown) => void;
  readCache = () => new Promise((resolve) => { settle = resolve; });
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(config);
  settle(undefined);
  timestamp += 30_001;
  readCache = async () => undefined;
  await POST(request());
  expect(cacheGet).toHaveBeenCalledTimes(2);
}, 1_000);

test("a stalled cache write cannot fail an otherwise successful evaluation", async () => {
  let settle!: () => void;
  writeCache = () => new Promise<void>((resolve) => { settle = resolve; });
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(config);
  settle();
}, 1_500);

test("failed shared evaluations are removed so the next request can recover", async () => {
  const fetchMock = mock(async () => new Response(null, { status: 503 }));
  globalThis.fetch = fetchMock as unknown as typeof fetch;
  const id = crypto.randomUUID();
  const responses = await Promise.all([POST(request(id)), POST(request(id))]);
  expect(responses.map((response) => response.status)).toEqual([502, 502]);
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(cacheSet).not.toHaveBeenCalled();
  fetchMock.mockResolvedValue(Response.json(config));
  expect((await POST(request(id))).status).toBe(200);
  expect(fetchMock).toHaveBeenCalledTimes(2);
});
