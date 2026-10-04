// The production agent pane in mock mode (`?mock`), replaying a recorded turn with its recorded
// timing. The mock daemon delivers a MockScript's steps at once; this page paces its deliveries by
// each event's `at` stamp (started + atMs), so the pane sees the same inter-arrival times the
// real daemon sent. Bench only: patches the mock's private `deliver`, no pane file changes.
//   /bench/stream/pane.html?mock&fixture=claude|codex&speed=1&limit=MS
import { MockAcpmuxSocket } from "../../src/agent-session/acpmux/mock";

const params = new URLSearchParams(location.search);
const fixture = params.get("fixture") ?? "claude";
const speed = Number(params.get("speed") ?? 1) || 1;
const limit = Number(params.get("limit") ?? 0) || Infinity;
const script = (await (await fetch(`./fixtures/${fixture}-turn.json`)).json()) as { steps: [number, string][] };
const steps = script.steps
  .filter(([atMs]) => atMs <= limit)
  // +100 ms: the mock stamps the prompt at the turn start, and rows sort by time.
  .map(([atMs, text]) => ({
    atMs: atMs + 100,
    update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
  }));
window.cmuxAcpmuxMockScript = { steps, endAtMs: (steps.at(-1)?.atMs ?? 0) + 50 };

type Message = { method?: string; params?: { kind?: string; at?: number } };
const proto = MockAcpmuxSocket.prototype as unknown as { deliver(message: unknown): void };
const deliver = proto.deliver;
let firstAt: number | undefined;
let base = 0;
let releaseAt = 0;
proto.deliver = function (this: unknown, message: unknown) {
  const event = message as Message;
  const kind = event.method === "_acpmux/event" ? event.params?.kind : undefined;
  const timed = kind === "agent_message_chunk" || kind === "agent_thought_chunk";
  if (timed && event.params?.at !== undefined) {
    if (firstAt === undefined) {
      firstAt = event.params.at;
      base = performance.now() + 20;
    }
    releaseAt = Math.max(releaseAt, base + (event.params.at - firstAt) / speed);
  }
  if (firstAt === undefined) return deliver.call(this, message);
  const wait = Math.max(0, releaseAt - performance.now());
  // Later events (the turn result) keep their order behind the paced chunks.
  setTimeout(() => {
    deliver.call(this, message);
    record(event);
  }, wait);
};

/// The instrument (instrument.js) hooks real WebSockets; the mock is not one, so log here.
function record(event: Message): void {
  const stream = (window as unknown as { __stream?: { ws: unknown[] } }).__stream;
  if (!stream) return;
  const update = (event.params as { msg?: { params?: { update?: { content?: { text?: string } } } } })?.msg?.params
    ?.update;
  const text = update?.content?.text;
  stream.ws.push([
    performance.now(),
    JSON.stringify(event).length,
    event.params?.kind,
    typeof text === "string" ? text.length : -1,
  ]);
}

await import("../../src/agent-session/acpmux/dev.tsx");
