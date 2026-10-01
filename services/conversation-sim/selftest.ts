// Self-test: boots server.ts as a subprocess on a random port and checks the protocol.
// Run: bun run services/conversation-sim/selftest.ts
import { join } from "node:path";
import { PNG_SIGNATURE, sniffImageSize } from "./png";

const port = 20000 + Math.floor(Math.random() * 20000);
const base = `http://127.0.0.1:${port}`;
const proc = Bun.spawn(["bun", "run", join(import.meta.dir, "server.ts")], {
  env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", LOG: "" },
  stdout: "pipe",
  stderr: "inherit",
});
const serverLog: string[] = [];
void (async () => {
  const dec = new TextDecoder();
  for await (const chunk of proc.stdout) serverLog.push(...dec.decode(chunk).split("\n").filter(Boolean));
})();

let passed = 0;
function check(cond: unknown, what: string): asserts cond {
  if (!cond) throw new Error(`FAIL: ${what}`);
  passed++;
  console.log(`  ok  ${what}`);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Frame = { jsonrpc: "2.0"; id?: number; method?: string; params?: any; result?: any; error?: { code: number; message: string } };

class Client {
  ws!: WebSocket;
  frames: Frame[] = []; // notifications, in arrival order
  closed = false;
  private nextId = 0;
  private pending = new Map<number, { res: (f: Frame) => void }>();
  private waiters: (() => void)[] = [];

  static async connect(conversation: string) {
    const c = new Client();
    c.ws = new WebSocket(`ws://127.0.0.1:${port}/ws?conversation=${conversation}`);
    c.ws.onmessage = (e) => {
      const f: Frame = JSON.parse(String(e.data));
      if (f.id !== undefined && c.pending.has(f.id)) {
        c.pending.get(f.id)!.res(f);
        c.pending.delete(f.id);
      } else c.frames.push(f);
      c.waiters.splice(0).forEach((w) => w());
    };
    c.ws.onclose = () => {
      c.closed = true;
      c.waiters.splice(0).forEach((w) => w());
    };
    await new Promise<void>((res, rej) => {
      c.ws.onopen = () => res();
      c.ws.onerror = () => rej(new Error("ws error"));
    });
    return c;
  }
  raw(method: string, params: unknown): Promise<Frame> {
    const id = ++this.nextId;
    return new Promise((res) => {
      this.pending.set(id, { res });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }
  async call(method: string, params: unknown = {}) {
    const f = await this.raw(method, params);
    if (f.error) throw new Error(`${method} error ${f.error.code} ${f.error.message}`);
    return f.result;
  }
  async waitFor<T>(pred: () => T | undefined | false, timeoutMs: number, what: string): Promise<T> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const v = pred();
      if (v) return v;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timeout waiting for ${what}`);
      await Promise.race([new Promise<void>((r) => this.waiters.push(r)), sleep(Math.min(left, 100))]);
    }
  }
  events() {
    return this.frames.filter((f) => f.method === "event").map((f) => f.params);
  }
  close() {
    this.ws.close();
  }
}

async function post(path: string, body?: unknown) {
  const r = await fetch(base + path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) });
  if (!r.ok) throw new Error(`${path} -> ${r.status} ${await r.text()}`);
  return r.json();
}

async function main() {
  for (let i = 0; ; i++) {
    try {
      if ((await fetch(base + "/healthz").then((r) => r.text())) === "ok") break;
    } catch {}
    if (i > 100) throw new Error("server did not start");
    await sleep(100);
  }
  console.log(`server up on ${base}`);
  const k = await post("/admin/knobs", {
    failRate: 0,
    historyFailRate: 0,
    duplicateRate: 0,
    latencyScale: 0.02,
    disconnectEverySeconds: 0,
    botIntervalScale: 10000,
  });
  const kGet = await fetch(base + "/admin/knobs").then((r) => r.json());
  check(kGet.latencyScale === 0.02 && kGet.botIntervalScale === 10000 && k.failRate === 0, "knobs POST applies and GET reads back");

  console.log("hello");
  const c = await Client.connect("group");
  const before = await c.raw("history", { limit: 5 });
  check(before.error?.code === -32003, "requests before hello are rejected (-32003)");
  const h = await c.call("hello", { clientId: "selftest-1" });
  check(h.conversation.id === "group" && h.conversation.title === "cmux" && h.conversation.kind === "group", "hello returns group conversation 'cmux'");
  check(h.conversation.participants.length === 4 && h.conversation.participants.every((p: any) => /^#[0-9A-F]{6}$/i.test(p.colorHex)), "4 participants with colorHex");
  check(h.me.isMe && h.me.initials === "AA", "me is Aziz Albahar (AA)");
  check(h.headSeq >= 19_000 && h.lagged === false && typeof h.serverTime === "number", `headSeq=${h.headSeq} lagged=false`);

  console.log("history paging");
  const newest = await c.call("history", { beforeSeq: null, limit: 50 });
  const seqs = (ms: any[]) => ms.map((m) => m.seq);
  const contiguous = (s: number[]) => s.every((v, i) => i === 0 || v === s[i - 1] + 1);
  check(newest.messages.length === 50 && contiguous(seqs(newest.messages)), "newest page: 50 contiguous ascending seqs");
  check(newest.messages.at(-1).seq === h.headSeq && newest.hasMore === true, "newest page ends at headSeq and hasMore");
  const first = newest.messages[0].seq;
  const older = await c.call("history", { beforeSeq: first, limit: 50 });
  check(older.messages.length === 50 && contiguous(seqs(older.messages)), "older page: 50 contiguous ascending seqs");
  check(older.messages.at(-1).seq === first - 1 && older.messages.every((m: any) => m.seq < first), "older page strictly older, ends at beforeSeq-1");
  check(older.hasMore === true, "older page hasMore");
  const oldest = await c.call("history", { beforeSeq: 10, limit: 50 });
  check(oldest.messages.length === 9 && oldest.messages[0].seq === 1 && oldest.hasMore === false, "page reaching seq 1 has hasMore=false");
  const empty = await c.call("history", { beforeSeq: 1, limit: 50 });
  check(empty.messages.length === 0 && empty.hasMore === false, "beforeSeq=1 is empty, hasMore=false");
  const sentAts = newest.messages.map((m: any) => m.sentAt);
  check(sentAts.every((t: number, i: number) => i === 0 || t > sentAts[i - 1]), "sentAt strictly increasing with seq");

  console.log("send");
  const cmid = `selftest-${crypto.randomUUID()}`;
  const [s1, s2] = await Promise.all([
    c.call("send", { clientMessageId: cmid, text: "hello from selftest" }),
    c.call("send", { clientMessageId: cmid, text: "hello from selftest" }),
  ]);
  const s3 = await c.call("send", { clientMessageId: cmid, text: "hello from selftest (retry)" });
  check(s1.message.id === s2.message.id && s2.message.id === s3.message.id, "send idempotent on clientMessageId (concurrent + retry)");
  check(s1.message.clientMessageId === cmid && s1.message.senderId === "aziz" && s1.message.seq === h.headSeq + 1, "sent message echoes clientMessageId, is mine, seq=head+1");
  const mid = s1.message.id;
  await c.waitFor(() => c.events().find((e) => e.kind === "message.created" && e.message.id === mid), 3000, "message.created");
  check(true, "message.created event received for my send");
  await c.waitFor(
    () => c.events().find((e) => e.kind === "message.updated" && e.message.id === mid && e.message.status === "delivered"),
    5000,
    "delivered update",
  );
  check(true, "later message.updated with status=delivered");
  check(c.events().filter((e) => e.kind === "message.created" && e.message.id === mid).length === 1, "exactly one message.created for the idempotent send");
  const evSeqs = c.events().map((e) => e.eventSeq);
  check(contiguous(evSeqs), "live eventSeqs arrive in order without gaps");

  console.log("direct read receipts");
  const d = await Client.connect("direct");
  const dh = await d.call("hello", { clientId: "selftest-d" });
  check(dh.conversation.kind === "direct" && dh.conversation.participants.some((p: any) => p.initials === "JA"), "direct conversation with John Appleseed");
  const dmsg = (await d.call("send", { clientMessageId: `d-${crypto.randomUUID()}`, text: "yo" })).message;
  await d.waitFor(() => d.events().find((e) => e.message.id === dmsg.id && e.message.status === "read" && e.message.readAt), 5000, "read");
  check(true, "direct: my message becomes read with readAt");
  d.close();

  console.log("react / edit");
  const reacted = await c.call("react", { messageId: mid, reaction: "heart" });
  check(reacted.message.reactions.some((r: any) => r.participantId === "aziz" && r.reaction === "heart"), "react adds my reaction");
  const unreacted = await c.call("react", { messageId: mid, reaction: null });
  check(!unreacted.message.reactions.some((r: any) => r.participantId === "aziz"), "react null removes my reaction");
  const edited = await c.call("edit", { messageId: mid, text: "edited text" });
  check(edited.message.text === "edited text" && edited.message.editedAt > 0, "edit sets text and editedAt");
  const badEdit = await c.raw("edit", { messageId: newest.messages.find((m: any) => m.senderId !== "aziz").id, text: "x" });
  check(badEdit.error?.code === -32602, "editing someone else's message is rejected");

  console.log("resume");
  await c.waitFor(() => c.events().some((e) => e.kind === "message.updated" && e.message.text === "edited text"), 3000, "edit event");
  await sleep(300);
  const lastSeen = Math.max(...c.events().map((e) => e.eventSeq));
  c.close();
  await c.waitFor(() => c.closed, 2000, "close");
  const burst = await post("/admin/burst?conversation=group&count=7&intervalMs=0");
  check(burst.headEventSeq >= lastSeen + 7, `burst while offline (headEventSeq ${lastSeen} -> ${burst.headEventSeq})`);
  const r = await Client.connect("group");
  const rh = await r.call("hello", { clientId: "selftest-1", resumeAfterEventSeq: lastSeen });
  check(rh.lagged === false && rh.headEventSeq === burst.headEventSeq, "resume hello not lagged");
  await r.waitFor(() => r.frames.find((f) => f.method === "replayDone"), 3000, "replayDone");
  const doneIdx = r.frames.findIndex((f) => f.method === "replayDone");
  const replayed = r.frames.slice(0, doneIdx).filter((f) => f.method === "event").map((f) => f.params.eventSeq);
  const expected = Array.from({ length: rh.headEventSeq - lastSeen }, (_, i) => lastSeen + 1 + i);
  check(JSON.stringify(replayed) === JSON.stringify(expected), `replay delivered events ${lastSeen + 1}..${rh.headEventSeq} in order before replayDone`);
  const replayedMsgs = r.frames.slice(0, doneIdx).filter((f) => f.method === "event" && f.params.kind === "message.created");
  check(replayedMsgs.length >= 7, "replay includes the 7 burst messages");

  console.log("lagged");
  const lagFrom = rh.headEventSeq;
  r.close();
  await post("/admin/burst?conversation=group&count=520&intervalMs=0");
  const l = await Client.connect("group");
  const lh = await l.call("hello", { clientId: "selftest-1", resumeAfterEventSeq: lagFrom });
  check(lh.lagged === true, "gap > 500 events returns lagged=true");
  await sleep(500);
  check(!l.frames.some((f) => f.method === "replayDone" || (f.method === "event" && f.params.eventSeq <= lh.headEventSeq)), "lagged: no replay and no replayDone");
  const future = await Client.connect("group");
  const fh = await future.call("hello", { clientId: "x", resumeAfterEventSeq: lh.headEventSeq + 1000 });
  check(fh.lagged === true, "resume cursor ahead of server head returns lagged=true");
  future.close();

  console.log("history failure knob");
  await post("/admin/knobs", { historyFailRate: 1 });
  const hf = await l.raw("history", { limit: 10 });
  check(hf.error?.code === -32001 && hf.error.message === "upstream timeout", "historyFailRate=1 -> -32001 upstream timeout");
  await post("/admin/knobs", { historyFailRate: 0, failRate: 1 });
  const sf = await l.raw("send", { clientMessageId: `f-${crypto.randomUUID()}`, text: "x" });
  check(sf.error?.code === -32002 && sf.error.message === "not delivered", "failRate=1 -> -32002 not delivered");
  await post("/admin/knobs", { failRate: 0 });

  console.log("media");
  let img: any;
  for (let before: number | null = null; !img; ) {
    const page = await l.call("history", { beforeSeq: before, limit: 200 });
    img = page.messages.flatMap((m: any) => m.attachments)[0];
    before = page.messages[0].seq;
  }
  const t0 = performance.now();
  const res = await fetch(img.url);
  const bytes = new Uint8Array(await res.arrayBuffer());
  check(res.status === 200 && res.headers.get("content-type") === "image/png", `GET ${new URL(img.url).pathname} -> 200 image/png (${Math.round(performance.now() - t0)}ms)`);
  check(PNG_SIGNATURE.every((b, i) => bytes[i] === b), "media bytes start with PNG signature");
  const dims = sniffImageSize(bytes)!;
  check(Math.max(dims.width, dims.height) <= 1200 && Math.abs(dims.width / dims.height - img.width / img.height) < 0.02, `PNG ${dims.width}x${dims.height} matches ${img.width}x${img.height} aspect, longest edge <= 1200`);
  const up = await fetch(base + "/upload", { method: "POST", body: bytes, headers: { "content-type": "image/png" } }).then((x) => x.json());
  check(up.attachment.width === dims.width && up.attachment.height === dims.height, "upload parses PNG dimensions");
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0x02, 0x58, 0x03, 0x20, 3, 0, 0, 0, 0xff, 0xd9]);
  const upj = await fetch(base + "/upload", { method: "POST", body: jpeg, headers: { "content-type": "image/jpeg" } }).then((x) => x.json());
  check(upj.attachment.width === 800 && upj.attachment.height === 600 && upj.attachment.url.endsWith(".jpg"), "upload parses JPEG SOF dimensions");
  const back = new Uint8Array(await (await fetch(up.attachment.url)).arrayBuffer());
  check(back.length === bytes.length && back.every((b, i) => b === bytes[i]), "uploaded bytes served back verbatim");
  const withImg = await l.call("send", { clientMessageId: `img-${crypto.randomUUID()}`, text: "", attachmentIds: [up.attachment.id] });
  check(withImg.message.attachments[0]?.id === up.attachment.id, "send with attachmentIds attaches the upload");

  console.log("admin disconnect");
  await post("/admin/disconnect");
  await l.waitFor(() => l.closed, 3000, "socket drop");
  check(true, "admin disconnect drops sockets");

  console.log(`\nPASS ${passed} checks`);
}

let code = 0;
try {
  await main();
} catch (e) {
  console.error(String(e));
  console.error("--- server log tail ---\n" + serverLog.slice(-20).join("\n"));
  code = 1;
} finally {
  proc.kill();
}
process.exit(code);
