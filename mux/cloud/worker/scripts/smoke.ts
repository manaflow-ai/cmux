// Live smoke test against a running mux worker: create a conversation, send a
// message over the WebSocket, wait for the mux's reply.
// Usage: bun scripts/smoke.ts [baseUrl] [message] [mux replies to wait for]
// MUX_ACCESS_TOKEN (a Stack access token) signs in; otherwise MUX_DEV_USER picks
// the dev identity (default "smoke").
const base = process.argv[2] ?? "http://localhost:8787";
const text = process.argv[3] ?? "hello mux";
let remaining = Number(process.argv[4] ?? 1);
const auth = process.env.MUX_ACCESS_TOKEN
  ? `access_token=${process.env.MUX_ACCESS_TOKEN}`
  : `dev_user=${process.env.MUX_DEV_USER ?? "smoke"}`;

const created = await fetch(`${base}/api/conversations?${auth}`, { method: "POST", body: "{}" });
const { conversation } = (await created.json()) as { conversation: { id: string } };
const ws = new WebSocket(
  `${base.replace(/^http/, "ws")}/api/conversations/${conversation.id}/ws?${auth}`,
);
const timeout = setTimeout(() => {
  console.error("timed out waiting for a reply");
  process.exit(1);
}, 600_000);
ws.onmessage = (event) => {
  const frame = JSON.parse(String(event.data));
  if (frame.type === "message") {
    const text = frame.message.parts.map((p: { text?: string }) => p.text ?? "").join(" ");
    console.log(`${frame.message.senderId}: ${text}`);
  } else console.log(frame.type);
  if (frame.type === "snapshot")
    ws.send(JSON.stringify({ type: "send", clientId: "c1", parts: [{ type: "text", text }] }));
  if (frame.type === "message" && frame.message.senderId.startsWith("mux-") && --remaining === 0) {
    clearTimeout(timeout);
    ws.close();
  }
};
