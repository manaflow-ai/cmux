import { serve, type RelaySocket } from "./runtime";

export type RelayAuthorization = (token: string) => Promise<boolean>;
type Link = {
  token: string;
  upstream?: WebSocket;
  queue: (string | Uint8Array<ArrayBuffer>)[];
  queuedBytes: number;
};

/** Loopback-only WebSocket carrier. The HTTPS ingress owns TLS, never auth. */
export function startHugeBlueRelay(input: {
  authorize: RelayAuthorization;
  upstream: string;
  port: number;
  recheckMs?: number;
}) {
  const peers = new Set<RelaySocket<Link>>();
  let checking = false;
  const denied = () => new Response("unauthorized", { status: 401, headers: { "cache-control": "no-store" } });
  const authorized = async (token: string) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        input.authorize(token).catch(() => false),
        new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), 3_000); }),
      ]);
    } finally { clearTimeout(timer); }
  };
  const server = serve<Link>({
    hostname: "127.0.0.1",
    port: input.port,
    async fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/healthz") return Response.json({ ok: true, connections: peers.size });
      if (url.pathname !== "/v1/link" || request.headers.has("origin")) return new Response("not found", { status: 404 });
      const tokens = url.searchParams.getAll("token");
      if (tokens.length !== 1 || !tokens[0] || !await authorized(tokens[0])) return denied();
      if (peers.size >= 64) return new Response("busy", { status: 503 });
      if (server.upgrade(request, { data: { token: tokens[0], queue: [], queuedBytes: 0 } })) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      maxPayloadLength: 4 * 1024 * 1024,
      backpressureLimit: 4 * 1024 * 1024,
      closeOnBackpressureLimit: true,
      open(peer) {
        peers.add(peer);
        const upstream = new WebSocket(input.upstream);
        upstream.binaryType = "arraybuffer";
        peer.data.upstream = upstream;
        upstream.onopen = () => {
          for (const frame of peer.data.queue.splice(0)) upstream.send(typeof frame === "string" ? frame : new Uint8Array(frame));
          peer.data.queuedBytes = 0;
        };
        upstream.onmessage = (event) => { peer.send(event.data); };
        upstream.onerror = () => peer.close(1011, "upstream unavailable");
        upstream.onclose = () => peer.close(1000, "upstream closed");
      },
      message(peer, frame) {
        const upstream = peer.data.upstream;
        if (upstream?.readyState === WebSocket.OPEN) {
          if (upstream.bufferedAmount > 4 * 1024 * 1024) return peer.close(1013, "backpressure");
          upstream.send(typeof frame === "string" ? frame : new Uint8Array(frame));
          return;
        }
        peer.data.queuedBytes += typeof frame === "string" ? Buffer.byteLength(frame) : frame.byteLength;
        if (peer.data.queuedBytes > 128 * 1024) return peer.close(1009, "queue exceeded");
        peer.data.queue.push(typeof frame === "string" ? frame : new Uint8Array(frame));
      },
      close(peer) {
        peers.delete(peer);
        const upstream = peer.data.upstream;
        if (upstream) { upstream.onclose = null; upstream.onerror = null; upstream.close(); }
        peer.data.token = "";
      },
    },
  });
  const timer = setInterval(async () => {
    if (checking) return;
    checking = true;
    try {
      await Promise.all([...peers].map(async (peer) => {
        if (!await authorized(peer.data.token)) peer.close(1008, "authorization expired");
      }));
    } finally { checking = false; }
  }, input.recheckMs ?? 1_000);
  return { server, async stop() { clearInterval(timer); for (const peer of peers) peer.close(1001, "shutdown"); await server.stop(true); } };
}
