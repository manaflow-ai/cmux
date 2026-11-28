// chat-100k-flat.bench.ts LAYER=store|transport: one chat's page with a part of the pane cut away, so a ratio can be
// split by component (attribution by subtraction: transport, store minus transport, pane minus store).
//
//   store      the shipped client (direct.ts AcpmuxDirectClient), following its newest row, its snapshots read by no
//              React: the reducer, the held window and the snapshot it hands the pane, and nothing drawn.
//   transport  a bare WebSocket that attaches the same way and parses every record it is sent, keeping the newest
//              HELD (1000) of them as the held window keeps that many: the wire and JSON, no store, no DOM.
//
// Both draw one text node: the newest "Answer N:", "Grown answer N:" or "Running step N:" they have seen, so the
// bench's textContent waits read them as they read the pane, and the page's DOM stays a few elements at any length.
import { AcpmuxDirectClient } from "../../src/agent-session/acpmux/direct";
import { devHostParams } from "../../src/dev-host/host";

const HELD = 1000;
const MARK = /(Grown answer|Answer|Running step) \d+:/g;
const marker = document.getElementById("marker")!;
const text = document.createTextNode("");
marker.append(text);
// The newest mark in `raw`, drawn if there is one. The pre-check keeps a record without any off the regex.
const mark = (raw: string) => {
  if (raw.indexOf("Answer ") < 0 && raw.indexOf("answer ") < 0 && raw.indexOf("Running step ") < 0) return;
  let last: string | undefined;
  for (const match of raw.matchAll(MARK)) last = match[0];
  if (last && text.data !== last) text.data = last;
};

const host = devHostParams(location.hash);
const layer = new URLSearchParams(location.search).get("layer");
if (!host?.sessionId) throw new Error("flat-layers: #endpoint=…&token=…&session=… required");

if (layer === "store") {
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: host.endpoint,
      token: host.token,
      sessionId: host.sessionId,
    },
    (snapshot) => {
      // The newest rows only: what a pane following its newest row reads of a snapshot.
      const rows = (snapshot as { rows?: unknown[] }).rows ?? [];
      mark(JSON.stringify(rows.slice(-4)));
    },
  );
  client.setFollowing(true);
  (globalThis as { __flatLayerClient?: unknown }).__flatLayerClient = client;
} else if (layer === "transport") {
  const held: unknown[] = [];
  let next = 0;
  const keep = (record: unknown) => {
    if (held.length < HELD) held.push(record);
    else held[next] = record;
    next = (next + 1) % HELD;
  };
  const socket = new WebSocket(host.endpoint);
  let id = 0;
  const call = (method: string, params: Record<string, unknown>) =>
    socket.send(JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }));
  socket.onopen = () => {
    call("initialize", { protocolVersion: 1, token: host.token });
    call("_acpmux/attach", { sessionId: host.sessionId, limit: 400 });
  };
  socket.onmessage = (event) => {
    const raw = String(event.data);
    const message = JSON.parse(raw) as {
      method?: string;
      params?: unknown;
      result?: { events?: unknown[] };
    };
    if (message.method === "_acpmux/event") keep(message.params);
    else for (const record of message.result?.events ?? []) keep(record);
    mark(raw);
  };
  (globalThis as { __flatLayerHeld?: unknown }).__flatLayerHeld = held;
} else {
  throw new Error(`flat-layers: ?layer=store|transport, not ${layer}`);
}
