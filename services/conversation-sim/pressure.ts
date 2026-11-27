// Pressure CLI for conversation-sim. SIM_URL env overrides http://127.0.0.1:4870.
//
//   bun pressure.ts burst <group|direct> <count> [intervalMs]
//   bun pressure.ts disconnect
//   bun pressure.ts knobs [key=value ...]        (no args prints current knobs)
//   bun pressure.ts state
//   bun pressure.ts client <group|direct> [sendEverySeconds=8]
//       second human-like client signed in as "me": sends, retries failed sends with
//       the same clientMessageId, reacts, edits, and resumes after drops
//   bun pressure.ts flood <group|direct> <count>  (send <count> of my messages back to back)

import { messageText } from "./corpus";

const BASE = (process.env.SIM_URL ?? "http://127.0.0.1:4870").replace(/\/$/, "");
const WS_BASE = BASE.replace(/^http/, "ws");
const [cmd, ...args] = process.argv.slice(2);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function http(method: string, path: string, body?: unknown) {
  const r = await fetch(BASE + path, { method, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${text}`);
  return text;
}

class Session {
  ws!: WebSocket;
  lastEventSeq: number | null = null;
  private id = 0;
  private pending = new Map<number, (f: any) => void>();
  constructor(public conversation: string, public onNotify: (f: any) => void = () => {}) {}

  async open() {
    this.ws = new WebSocket(`${WS_BASE}/ws?conversation=${this.conversation}`);
    this.ws.onmessage = (e) => {
      const f = JSON.parse(String(e.data));
      if (f.id !== undefined && this.pending.has(f.id)) {
        this.pending.get(f.id)!(f);
        this.pending.delete(f.id);
        return;
      }
      if (f.method === "event") {
        if (this.lastEventSeq !== null && f.params.eventSeq <= this.lastEventSeq) return; // duplicate
        this.lastEventSeq = f.params.eventSeq;
      }
      this.onNotify(f);
    };
    this.ws.addEventListener("close", () => {
      for (const res of this.pending.values()) res({ error: { code: -1, message: "socket closed" } });
      this.pending.clear();
    });
    await new Promise<void>((res, rej) => {
      this.ws.onopen = () => res();
      this.ws.onerror = () => rej(new Error(`cannot connect to ${WS_BASE}`));
    });
    const hello = await this.call("hello", { clientId: `pressure-${process.pid}`, resumeAfterEventSeq: this.lastEventSeq ?? undefined });
    if (hello.result?.lagged || this.lastEventSeq === null) this.lastEventSeq = hello.result?.headEventSeq ?? 0;
    return hello.result;
  }
  call(method: string, params: unknown): Promise<any> {
    const id = ++this.id;
    return new Promise((res) => {
      this.pending.set(id, res);
      if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      else res({ error: { code: -1, message: "socket closed" } });
    });
  }
  closed() {
    return new Promise<void>((r) => this.ws.addEventListener("close", () => r()));
  }
}

async function sendWithRetry(s: Session, text: string) {
  const clientMessageId = `pressure-${crypto.randomUUID()}`;
  for (let attempt = 1; attempt <= 5; attempt++) {
    const r = await s.call("send", { clientMessageId, text });
    if (r.result) return r.result.message;
    console.log(`  send attempt ${attempt} failed: ${r.error?.message}`);
    await sleep(500 * attempt);
  }
  return null;
}

async function runClient(conversation: string, everySec: number) {
  const s = new Session(conversation, (f) => {
    if (f.method === "event") {
      const m = f.params.message;
      const preview = (m.text || `[${m.attachments.length} image]`).replace(/\s+/g, " ").slice(0, 60);
      console.log(`#${f.params.eventSeq} ${f.params.kind} seq=${m.seq} ${m.senderId}${m.status ? ` (${m.status})` : ""}: ${preview}`);
    } else if (f.method === "replayDone") console.log("-- replayDone");
  });
  let mine: any[] = [];
  for (;;) {
    try {
      const h = await s.open();
      console.log(`connected conv=${conversation} headSeq=${h.headSeq} headEventSeq=${h.headEventSeq} lagged=${h.lagged}`);
      let alive = true;
      s.closed().then(() => (alive = false));
      while (alive) {
        await sleep(everySec * 1000 * (0.5 + Math.random()));
        if (!alive) break;
        const roll = Math.random();
        if (roll < 0.1 && mine.length) {
          const m = mine[Math.floor(Math.random() * mine.length)];
          await s.call("edit", { messageId: m.id, text: `${m.text} (edited)` });
        } else if (roll < 0.25) {
          const page = await s.call("history", { beforeSeq: null, limit: 10 });
          const target = page.result?.messages?.at(-1);
          if (target) await s.call("react", { messageId: target.id, reaction: "thumbsup" });
        } else {
          await s.call("typing", { isTyping: true });
          const m = await sendWithRetry(s, messageText(Math.random));
          if (m) mine = [...mine.slice(-20), m];
        }
      }
      console.log("disconnected, resuming in 1s");
    } catch (e) {
      console.log(`connect failed: ${(e as Error).message}; retrying in 2s`);
    }
    await sleep(1000 + Math.random() * 1000);
  }
}

async function main() {
  switch (cmd) {
    case "burst": {
      const [conv = "group", count = "20", iv] = args;
      const q = new URLSearchParams({ conversation: conv, count });
      if (iv !== undefined) q.set("intervalMs", iv);
      console.log(await http("POST", `/admin/burst?${q}`));
      break;
    }
    case "disconnect":
      console.log(await http("POST", "/admin/disconnect"));
      break;
    case "knobs": {
      if (!args.length) {
        console.log(await http("GET", "/admin/knobs"));
        break;
      }
      const body: Record<string, number> = {};
      for (const a of args) {
        const [k, v] = a.split("=");
        body[k] = Number(v);
      }
      console.log(await http("POST", "/admin/knobs", body));
      break;
    }
    case "state":
      console.log(await http("GET", "/admin/state"));
      break;
    case "client":
      await runClient(args[0] ?? "group", Number(args[1] ?? 8));
      break;
    case "flood": {
      const [conv = "group", count = "20"] = args;
      const s = new Session(conv);
      await s.open();
      const results = await Promise.all(Array.from({ length: Number(count) }, (_, i) => sendWithRetry(s, `flood ${i + 1}/${count}`)));
      console.log(`sent ${results.filter(Boolean).length}/${count}`);
      s.ws.close();
      break;
    }
    default:
      console.log(
        "usage: bun pressure.ts burst <conv> <count> [intervalMs] | disconnect | knobs [k=v ...] | state | client <conv> [sendEverySeconds] | flood <conv> <count>",
      );
      process.exit(cmd ? 1 : 0);
  }
}

await main();
