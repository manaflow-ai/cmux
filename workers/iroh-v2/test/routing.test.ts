import { expect, test } from "bun:test";
import { encodeBase64URL, issueTicket } from "../src/crypto";
import { readInternalRequest, routeControl, SETUP_HEADER, type RoutingDependencies } from "../src/routing";
import { descriptor as device } from "./fixtures";

const key = encodeBase64URL(new Uint8Array(32).fill(9));
const setup = { schemaId: "session.open.v1", requestId: "request", device };
const encodedSetup = encodeBase64URL(new TextEncoder().encode(JSON.stringify(setup)));
function fixture() {
  const calls = { stack: 0, open: 0, team: 0 };
  const dependencies: RoutingDependencies = {
    environment: device.identity.environment, projectId: device.identity.projectId, ticketKeys: { test: key }, now: () => 100,
    stack: { verify: async () => {
      calls.stack++;
      return { environment: device.identity.environment, projectId: device.identity.projectId, teamId: device.identity.teamId, userId: device.identity.userId, verifiedAt: 100 };
    } },
    chargeOpen: async userId => { expect(userId).toBe(device.identity.userId); calls.open++; },
    dispatchTeam: async (teamId, request) => {
      calls.team++;
      expect(teamId).toBe(device.identity.teamId);
      expect(request.headers.get("cookie")).toBeNull();
      expect(request.headers.get("authorization")).toBeNull();
      const internal = await readInternalRequest(request);
      expect(internal.authority.userId).toBe(device.identity.userId);
      expect(internal.setup.device).toEqual(device);
      return Response.json({ path: internal.path, issueTicket: internal.issueTicket });
    },
  };
  return { calls, dependencies };
}

test("forged private headers and cookies cannot become trusted DO authority", async () => {
  const { calls, dependencies } = fixture();
  const result = await routeControl(new Request("https://api.example/v2/control/session", {
    method: "POST", headers: {
      "content-type": "application/json", authorization: "Bearer stack-token", cookie: "private=value",
      "x-cmux-v2-verified-authority": JSON.stringify({ authority: { userId: "victim", teamId: "victim-team" } }),
    }, body: JSON.stringify(setup),
  }), dependencies);
  expect(result.status).toBe(200);
  expect(await result.json()).toMatchObject({ path: "/session", issueTicket: true });
  expect(calls).toEqual({ stack: 1, open: 1, team: 1 });
});

test("valid bound HMAC tickets bypass Stack and cannot authorize another endpoint", async () => {
  const { calls, dependencies } = fixture();
  const ticket = await issueTicket(device, "test", key, 99);
  const request = (encoded: string) => new Request("https://api.example/v2/requests", {
    method: "POST", headers: { "content-type": "application/json", authorization: "IrohTicket " + ticket.token, [SETUP_HEADER]: encoded },
    body: JSON.stringify({ schemaId: "relay.request.v1", requestId: "request" }),
  });
  expect((await routeControl(request(encodedSetup), dependencies)).status).toBe(200);
  const changed = encodeBase64URL(new TextEncoder().encode(JSON.stringify({ ...setup, device: { ...device, endpointId: "f".repeat(64) } })));
  const rejected = await routeControl(request(changed), dependencies);
  expect(rejected.status).toBe(403);
  expect(await rejected.json()).toMatchObject({ code: "identity_mismatch" });
  expect(calls).toEqual({ stack: 0, open: 0, team: 1 });
});

test("unsupported paths, methods, oversized setup and mismatched aliases fail before Stack", async () => {
  const { calls, dependencies } = fixture();
  const requests = [
    new Request("https://api.example/socket"),
    new Request("https://api.example/v2/control/session"),
    new Request("https://api.example/v2/requests", { method: "POST", headers: { "content-type": "application/json", [SETUP_HEADER]: "a".repeat(24000) } }),
    new Request("https://api.example/v2/tickets", { method: "POST", headers: { "content-type": "application/json", [SETUP_HEADER]: encodedSetup }, body: JSON.stringify({ schemaId: "relay.request.v1", requestId: "request" }) }),
  ];
  const statuses = [];
  for (const request of requests) statuses.push((await routeControl(request, dependencies)).status);
  expect(statuses).toEqual([404, 405, 413, 400]);
  expect(calls).toEqual({ stack: 0, open: 0, team: 0 });
});

test("retired Vercel device and relay paths are not part of the v2 Worker", async () => {
  const { calls, dependencies } = fixture();
  const responses = await Promise.all([
    routeControl(new Request("https://api.example/api/devices/iroh"), dependencies),
    routeControl(new Request("https://api.example/api/relay/token"), dependencies),
  ]);
  expect(responses.map(response => response.status)).toEqual([404, 404]);
  expect(calls).toEqual({ stack: 0, open: 0, team: 0 });
});

test("cross-environment setup never reaches Stack or a team object", async () => {
  const { calls, dependencies } = fixture();
  const result = await routeControl(new Request("https://api.example/v2/control/session", {
    method: "POST", headers: { "content-type": "application/json", authorization: "Bearer stack-token" },
    body: JSON.stringify({ ...setup, device: { ...device, identity: { ...device.identity, environment: "production" } } }),
  }), { ...dependencies, environment: "development" });
  expect(result.status).toBe(403);
  expect(calls).toEqual({ stack: 0, open: 0, team: 0 });
});
