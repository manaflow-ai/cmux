// Reads `wrangler tail --format json` on stdin (pretty-printed events, one after another) and prints one
// compact line per event: time, method, path, status, outcome, a Durable Object RPC method or cron, log
// lines and exceptions. Headers, bodies, query strings and addresses are dropped (the Actions log is public),
// and anything shaped like an email is redacted. Used by cmux-vm.yml's tail-production action.
import { createInterface } from "node:readline";

const redact = (text) => String(text).replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<email>");

const summarize = (event) => {
  const request = event.event?.request;
  const path = typeof request?.url === "string" ? request.url.replace(/^https?:\/\/[^/]+/, "").replace(/\?.*$/, "") : undefined;
  return {
    t: typeof event.eventTimestamp === "number" ? new Date(event.eventTimestamp).toISOString() : undefined,
    ...(request === undefined ? {} : { method: request.method, path }),
    ...(event.event?.response?.status === undefined ? {} : { status: event.event.response.status }),
    ...(event.event?.rpcMethod === undefined ? {} : { rpc: `${event.entrypoint ?? "do"}.${event.event.rpcMethod}` }),
    ...(event.event?.cron === undefined ? {} : { cron: event.event.cron }),
    outcome: event.outcome,
    wallMs: event.wallTime,
    ...(Array.isArray(event.logs) && event.logs.length > 0
      ? { logs: event.logs.map((log) => ({ level: log.level, message: redact(JSON.stringify(log.message)) })) }
      : {}),
    ...(Array.isArray(event.exceptions) && event.exceptions.length > 0
      ? { exceptions: event.exceptions.map((e) => ({ name: e.name, message: redact(e.message) })) }
      : {}),
  };
};

let buffer = [];
let depth = 0;
for await (const line of createInterface({ input: process.stdin })) {
  if (depth === 0 && !line.trimStart().startsWith("{")) continue;
  buffer.push(line);
  for (const ch of line.replace(/"(?:[^"\\]|\\.)*"/g, "")) {
    if (ch === "{" || ch === "[") depth += 1;
    else if (ch === "}" || ch === "]") depth -= 1;
  }
  if (depth > 0) continue;
  depth = 0;
  const text = buffer.join("\n").replace(/,(\s*[\]}])/g, "$1");
  buffer = [];
  try {
    const summary = summarize(JSON.parse(text));
    if (summary.path === "/healthz" && summary.status === 200) continue;
    console.log(JSON.stringify(summary));
  } catch {
    console.log(JSON.stringify({ unparsed: true, bytes: text.length }));
  }
}
