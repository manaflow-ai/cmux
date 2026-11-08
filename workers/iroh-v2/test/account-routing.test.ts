import { expect, test } from "bun:test";
import { encodeBase64URL, issueTicket } from "../src/crypto";
import { readInternalRequest, routeControl, SETUP_HEADER, type RoutingDependencies } from "../src/routing";
import { descriptor as device } from "./fixtures";

const key = encodeBase64URL(new Uint8Array(32).fill(9));
const encode = (value: unknown) => encodeBase64URL(new TextEncoder().encode(JSON.stringify(value)));
const setup = { schemaId: "session.open.v1", requestId: "request", device };

function fixture() {
  const calls = { stack: 0, open: 0, team: 0, account: [] as string[] };
  const dependencies: RoutingDependencies = {
    environment: device.identity.environment, projectId: device.identity.projectId, ticketKeys: { test: key }, now: () => 100,
    stack: { verify: async () => { calls.stack++; throw new Error("account routes never call Stack"); } },
    chargeOpen: async () => { calls.open++; },
    dispatchTeam: async () => { calls.team++; return new Response("team"); },
    dispatchAccount: async (userId, request) => {
      calls.account.push(userId);
      expect(request.headers.get("authorization")).toBeNull();
      const internal = await readInternalRequest(request);
      return Response.json({ path: internal.path, userId: internal.authority.userId, issueTicket: internal.issueTicket, input: internal.input ?? null });
    },
  };
  return { calls, dependencies };
}

const post = (authorization: string, encodedSetup = encode(setup), body: unknown = { schemaId: "account.directory.v1", requestId: "request" }) =>
  new Request("https://api.example/v2/account/requests", {
    method: "POST", headers: { "content-type": "application/json", authorization, [SETUP_HEADER]: encodedSetup }, body: JSON.stringify(body),
  });

test("account routes accept only a ticket and dispatch to the ticket's user", async () => {
  const { calls, dependencies } = fixture();
  const bearer = await routeControl(post("Bearer stack-token"), dependencies);
  expect(bearer.status).toBe(401);
  expect(await bearer.json()).toMatchObject({ code: "unauthorized" });
  const ticket = await issueTicket(device, "test", key, 99);
  const accepted = await routeControl(post("IrohTicket " + ticket.token), dependencies);
  expect(accepted.status).toBe(200);
  expect(await accepted.json() as unknown).toEqual({ path: "/request", userId: device.identity.userId, issueTicket: false, input: { schemaId: "account.directory.v1", requestId: "request" } });
  const socket = await routeControl(new Request("https://api.example/v2/account/socket", {
    headers: { upgrade: "websocket", authorization: "IrohTicket " + ticket.token, [SETUP_HEADER]: encode(setup) },
  }), dependencies);
  expect(await socket.json() as Record<string, unknown>).toMatchObject({ path: "/socket", userId: device.identity.userId });
  expect(calls).toEqual({ stack: 0, open: 0, team: 0, account: [device.identity.userId, device.identity.userId] });
});

test("a setup naming another user than the ticket is refused before any object", async () => {
  const { calls, dependencies } = fixture();
  const ticket = await issueTicket(device, "test", key, 99);
  const tampered = encode({ ...setup, device: { ...device, identity: { ...device.identity, userId: "victim" } } });
  const result = await routeControl(post("IrohTicket " + ticket.token, tampered), dependencies);
  expect(result.status).toBe(403);
  expect(await result.json()).toMatchObject({ code: "identity_mismatch" });
  expect(calls.account).toEqual([]);
});

test("unknown account paths, queries and wrong methods keep the existing 404/405 answers", async () => {
  const { calls, dependencies } = fixture();
  const statuses = [];
  for (const request of [
    new Request("https://api.example/v2/account"), new Request("https://api.example/v2/account/other"),
    new Request("https://api.example/v2/account/requests?x=1", { method: "POST" }),
    new Request("https://api.example/v2/account/requests"),
  ]) statuses.push((await routeControl(request, dependencies)).status);
  expect(statuses).toEqual([404, 404, 404, 405]);
  const ticket = await issueTicket(device, "test", key, 99);
  const team = await routeControl(new Request("https://api.example/v2/requests", {
    method: "POST", headers: { "content-type": "application/json", authorization: "IrohTicket " + ticket.token, [SETUP_HEADER]: encode(setup) },
    body: JSON.stringify({ schemaId: "relay.request.v1", requestId: "request" }),
  }), dependencies);
  expect(await team.text()).toBe("team");
  expect(calls).toEqual({ stack: 0, open: 0, team: 1, account: [] });
});
