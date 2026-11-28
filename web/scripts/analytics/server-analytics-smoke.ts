/** End-to-end server analytics smoke test. It never contacts PostHog. */
import { createServer } from "node:http";
import { captureServerEvent } from "../../services/analytics/serverEvents";

const received: Array<Record<string, unknown>> = [];
const server = createServer((request, response) => {
  if (request.method !== "POST" || request.url !== "/capture/") {
    response.writeHead(404).end();
    return;
  }
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk: string) => { body += chunk; });
  request.on("end", () => {
    try { received.push(JSON.parse(body) as Record<string, unknown>); } catch { response.writeHead(400).end(); return; }
    response.writeHead(200).end("ok");
  });
});

await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
if (!address || typeof address === "string") throw new Error("loopback collector did not bind");

try {
  const env = {
    VERCEL_ENV: "preview",
    CMUX_SERVER_ANALYTICS_FORCE: "1",
    CMUX_SERVER_ANALYTICS_SMOKE: "1",
    POSTHOG_HOST: `http://127.0.0.1:${address.port}`,
  };
  const fetchImpl = (input: RequestInfo | URL, init?: RequestInit) => fetch(input, init);
  const deps = { env, fetch: fetchImpl, defer: (task: () => Promise<void>) => void task(), now: () => new Date("2026-09-04T00:00:00.000Z") };
  await Promise.all([
    captureServerEvent({ event: "cloud_vm_created", distinctId: "smoke-user", teamId: "smoke-team", properties: { vm_id: "smoke-vm", plan_id: "pro" }, insertId: "smoke-cloud-vm-created" }, deps),
    captureServerEvent({ event: "coderouter_account_added", distinctId: "smoke-user", teamId: "smoke-team", properties: { provider: "codex", source: "native_api" }, insertId: "smoke-coderouter-account" }, deps),
  ]);
  if (received.length !== 2) throw new Error(`expected 2 captured events, got ${received.length}`);
  for (const event of received) {
    if (event.distinct_id !== "smoke-user") throw new Error("Stack user id was not preserved");
    const properties = event.properties as Record<string, unknown> | undefined;
    if (properties?.$groups === undefined) throw new Error("stack_team group was not preserved");
    if (Object.keys(properties ?? {}).some((key) => key.includes("token") || key.includes("cost"))) throw new Error("token or cost data reached PostHog transport");
  }
  console.log("PASS: server events reached the loopback collector; PostHog was not contacted");
} finally {
  await new Promise<void>((resolve) => server.close(() => resolve()));
}
