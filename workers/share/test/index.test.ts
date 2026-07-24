// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it, mock } from "bun:test";

mock.module("cloudflare:workers", () => ({
  DurableObject: class {},
}));

const workerPromise = import("../src/index").then((module) => module.default);

const DEPLOYMENT_ID = "9f1b71c3-7ef7-4aba-9046-8a39afda7e5a";

const env = {
  SHARE_SESSION: {},
  WORKER_VERSION_METADATA: {
    id: DEPLOYMENT_ID,
    tag: "test",
    timestamp: "2026-07-24T00:00:00.000Z",
  },
} as never;

function websocketRequest(version: string): Request {
  return new Request(
    `https://share.example.com/${version}/share/sessions/code12345/ws`,
    { headers: { upgrade: "websocket" } },
  );
}

describe("worker protocol discovery", () => {
  it("advertises protocol, terminal transport, and deployment identity", async () => {
    const worker = await workerPromise;
    const response = await worker.fetch(
      new Request("https://share.example.com/healthz"),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      service: "cmux-share",
      protocolVersion: 2,
      terminalTransportVersion: 1,
      deploymentId: DEPLOYMENT_ID,
    });
  });

  it("recognizes only the v2 WebSocket route", async () => {
    const worker = await workerPromise;
    const v2 = await worker.fetch(websocketRequest("v2"), env);
    expect(v2.status).toBe(503);
    expect(await v2.json()).toEqual({ error: "not_configured" });

    for (const version of ["v1", "v3"]) {
      const rejected = await worker.fetch(websocketRequest(version), env);
      expect(rejected.status).toBe(404);
      expect(await rejected.json()).toEqual({ error: "not_found" });
    }
  });
});
