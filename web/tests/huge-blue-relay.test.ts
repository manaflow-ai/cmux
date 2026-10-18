import { test, expect } from "bun:test";
import { serve } from "../../workers/huge-blue-relay/runtime";
import { startHugeBlueRelay } from "../../workers/huge-blue-relay/server";

function connected(url: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const peer = new WebSocket(url);
    peer.binaryType = "arraybuffer";
    peer.onopen = () => resolve(peer);
    peer.onerror = () => reject(new Error("connection failed"));
  });
}

test("relay rejects invalid tokens and preserves binary frames across rotation and reconnect", async () => {
  let allowed = "first";
  const upstream = serve({ hostname: "127.0.0.1", port: 0,
    fetch(request, server) { if (server.upgrade(request)) return; return new Response("upgrade", { status: 426 }); },
    websocket: { message(peer, frame) { peer.send(frame); } },
  });
  const relay = startHugeBlueRelay({ port: 0, upstream: `ws://127.0.0.1:${upstream.port}`, authorize: async (token) => token === allowed, recheckMs: 20 });
  const route = `http://127.0.0.1:${relay.server.port}/v1/link`;
  try {
    expect((await fetch(`${route}?token=wrong`)).status).toBe(401);
    expect((await fetch(`${route}?token=first&token=first`)).status).toBe(401);
    const first = await connected(`${route.replace("http:", "ws:")}?token=first`);
    const echoed = new Promise<ArrayBuffer>((resolve) => { first.onmessage = (event) => resolve(event.data); });
    first.send(new Uint8Array([0, 255, 129, 0, 10]));
    expect([...new Uint8Array(await echoed)]).toEqual([0, 255, 129, 0, 10]);
    const closed = new Promise<number>((resolve) => { first.onclose = (event) => resolve(event.code); });
    allowed = "second";
    expect(await closed).toBe(1008);
    expect((await fetch(`${route}?token=first`)).status).toBe(401);
    const second = await connected(`${route.replace("http:", "ws:")}?token=second`);
    second.close();
    const reconnected = await connected(`${route.replace("http:", "ws:")}?token=second`);
    reconnected.close();
  } finally { await relay.stop(); await upstream.stop(true); }
}, 10_000);

test("relay fails closed on ledger errors", async () => {
  const relay = startHugeBlueRelay({ port: 0, upstream: "ws://127.0.0.1:1", authorize: async () => { throw new Error("DB unavailable"); } });
  try { expect((await fetch(`http://127.0.0.1:${relay.server.port}/v1/link?token=x`)).status).toBe(401); }
  finally { await relay.stop(); }
});
