// Self-test: boots server.ts as a subprocess on a random port and checks the protocol.
// Run: bun run services/conversation-sim/selftest.ts
import { join } from "node:path";
import { PNG_SIGNATURE, proceduralPNG, sniffImageSize } from "./png";

const port = 20000 + Math.floor(Math.random() * 20000);
const base = `http://127.0.0.1:${port}`;
const proc = Bun.spawn(["bun", "run", join(import.meta.dir, "server.ts")], {
  env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", LOG: "", MAX_PINNED: "1" },
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

async function getState() {
  return fetch(base + "/admin/state").then((x) => x.json());
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
  check(h.unreadCount >= 60 && h.lastReadSeq < h.headSeq, `hello carries read state (unread=${h.unreadCount} lastReadSeq=${h.lastReadSeq})`);

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

  console.log("intl conversation");
  const intl = await Client.connect("intl");
  const ih = await intl.call("hello", { clientId: "selftest-i" });
  check(ih.conversation.title === "Amigos" && ih.conversation.participants.length === 4, "intl conversation 'Amigos' with 3 speakers");
  const ipage = await intl.call("history", { beforeSeq: null, limit: 60 });
  const others = ipage.messages.filter((m: any) => m.senderId !== "aziz").map((m: any) => m.text).join(" ");
  check(/[ぁ-んァ-ン一-龯]/.test(others) && /[¿¡ñ]/.test(others) && /\b(je|les|la|est)\b/i.test(others), "intl history mixes Japanese, Spanish and French");
  intl.close();

  console.log("react / edit");
  const reacted = await c.call("react", { messageId: mid, reaction: "heart" });
  check(reacted.message.reactions.some((r: any) => r.participantId === "aziz" && r.reaction === "heart"), "react adds my reaction");
  const unreacted = await c.call("react", { messageId: mid, reaction: null });
  check(!unreacted.message.reactions.some((r: any) => r.participantId === "aziz"), "react null removes my reaction");
  const emojiReacted = await c.call("react", { messageId: mid, reaction: "\u{1F525}" });
  check(emojiReacted.message.reactions.some((r: any) => r.participantId === "aziz" && r.reaction === "\u{1F525}"), "react accepts a custom emoji");
  const skinTone = await c.call("react", { messageId: mid, reaction: "\u{1F44F}\u{1F3FD}" });
  check(skinTone.message.reactions.filter((r: any) => r.participantId === "aziz").map((r: any) => r.reaction).join() === "\u{1F44F}\u{1F3FD}", "an emoji tapback replaces my previous one (skin tone kept)");
  for (const bad of ["fire", "\u{1F525}\u{1F525}", "a", ""]) {
    const rejected = await c.raw("react", { messageId: mid, reaction: bad });
    check(rejected.error?.code === -32602, `react rejects ${JSON.stringify(bad)} (not one emoji or tapback)`);
  }
  await c.call("react", { messageId: mid, reaction: null });
  const edited = await c.call("edit", { messageId: mid, text: "edited text" });
  check(edited.message.text === "edited text" && edited.message.editedAt > 0 && edited.message.editCount === 1, "edit sets text, editedAt and editCount");
  const badEdit = await c.raw("edit", { messageId: newest.messages.find((m: any) => m.senderId !== "aziz").id, text: "x" });
  check(badEdit.error?.code === -32602, "editing someone else's message is rejected");
  const unsent = await c.call("unsend", { messageId: mid });
  check(unsent.message.unsentAt > 0 && unsent.message.text === "" && unsent.message.attachments.length === 0, "unsend clears the message and sets unsentAt");
  const oldMine = newest.messages.find((m: any) => m.senderId === "aziz" && Date.now() - m.sentAt > 120_000);
  if (oldMine) {
    const late = await c.raw("unsend", { messageId: oldMine.id });
    check(late.error?.code === -32003, "unsend after two minutes is refused (-32003)");
  }
  await post("/admin/knobs", { unsendFailRate: 1 });
  const fresh = await c.call("send", { clientMessageId: crypto.randomUUID(), text: "take me back" });
  const refused = await c.raw("unsend", { messageId: fresh.message.id });
  check(refused.error?.code === -32005, "unsend refused at unsendFailRate (-32005)");
  await post("/admin/knobs", { unsendFailRate: 0 });
  const peer = await post("/admin/unsend?conversation=group");
  await c.waitFor(() => c.events().some((e) => e.kind === "message.updated" && e.message.id === peer.messageId && e.message.unsentAt > 0 && e.message.text === ""), 3000, "peer unsend event");
  check(true, "admin unsend: a participant takes back its newest message");

  console.log("mentions");
  const mtext = "hey Leo and Austin";
  const ms = await c.call("send", {
    clientMessageId: crypto.randomUUID(),
    text: mtext,
    mentions: [
      { participantId: "austin", location: 12, length: 6 },
      { participantId: "leo", location: 4, length: 3 },
    ],
  });
  check(
    JSON.stringify(ms.message.mentions) === JSON.stringify([
      { participantId: "leo", location: 4, length: 3 },
      { participantId: "austin", location: 12, length: 6 },
    ]),
    "send stores mentions sorted by location",
  );
  const badMention = await c.raw("send", { clientMessageId: crypto.randomUUID(), text: "hi", mentions: [{ participantId: "leo", location: 1, length: 5 }] });
  check(badMention.error?.code === -32602, "out-of-range mention is rejected");
  const keptEdit = await c.call("edit", { messageId: ms.message.id, text: "hey Leo and Lawrence" });
  check(JSON.stringify(keptEdit.message.mentions) === JSON.stringify([{ participantId: "leo", location: 4, length: 3 }]), "edit keeps only mentions whose text is unchanged");
  const am = await post("/admin/mention?conversation=group&target=aziz");
  check(am.ok && am.message.mentions[0].participantId === "aziz" && am.message.text.substr(am.message.mentions[0].location, am.message.mentions[0].length) === "Aziz", "admin mention: a bot mentions me by first name");
  const amEvent = await c.waitFor(() => c.events().find((e) => e.kind === "message.created" && e.message.id === am.message.id), 3000, "mention event");
  check(amEvent.message.mentions?.[0]?.participantId === "aziz", "mention arrives on the live event");
  let historyMentions = 0;
  let historyEmojiTapbacks = 0;
  const classicTapbacks = ["heart", "thumbsup", "thumbsdown", "haha", "exclamation", "question"];
  for (let before: number | null = null, pages = 0; pages < 8; pages++) {
    const page = await c.call("history", { beforeSeq: before, limit: 200 });
    for (const m of page.messages) for (const r of m.reactions) {
      if (classicTapbacks.includes(r.reaction)) continue;
      if (!/^\p{RGI_Emoji}$/v.test(r.reaction)) throw new Error(`FAIL: history reaction ${JSON.stringify(r.reaction)} in ${m.id} is neither a tapback nor one emoji`);
      historyEmojiTapbacks++;
    }
    for (const m of page.messages)
      for (const x of m.mentions ?? []) {
        if (m.text.slice(x.location, x.location + x.length) !== h.conversation.participants.find((p: any) => p.id === x.participantId).name.split(" ")[0])
          throw new Error(`FAIL: history mention range mismatch in ${m.id}`);
        historyMentions++;
      }
    before = page.messages[0].seq;
  }
  check(historyEmojiTapbacks > 0, `history carries custom emoji tapbacks (${historyEmojiTapbacks} in 1600 msgs)`);
  check(historyMentions > 0, `group history carries mentions whose ranges name the participant (${historyMentions} in 1600 msgs)`);

  console.log("text formatting");
  const runs = [
    { start: 0, length: 5, styles: ["italic", "bold"] },
    { start: 6, length: 7, effect: "explode" },
  ];
  const fmt = await c.call("send", { clientMessageId: `fmt-${crypto.randomUUID()}`, text: "hello formatted world", textRuns: runs });
  check(
    JSON.stringify(fmt.message.textRuns) === JSON.stringify([{ start: 0, length: 5, styles: ["bold", "italic"] }, { start: 6, length: 7, effect: "explode" }]),
    "send textRuns round-trip (styles in canonical order)",
  );
  const fmtPage = await c.call("history", { beforeSeq: null, limit: 5 });
  check(fmtPage.messages.some((m: any) => m.id === fmt.message.id && m.textRuns?.length === 2), "history carries textRuns");
  const badRange = await c.raw("send", { clientMessageId: `fmt-${crypto.randomUUID()}`, text: "abc", textRuns: [{ start: 2, length: 5, styles: ["bold"] }] });
  check(badRange.error?.code === -32602, "out-of-range textRuns rejected");
  const badEffect = await c.raw("send", { clientMessageId: `fmt-${crypto.randomUUID()}`, text: "abc", textRuns: [{ start: 0, length: 3, effect: "wobble" }] });
  check(badEffect.error?.code === -32602, "unknown text effect rejected");
  const overlap = await c.raw("send", { clientMessageId: `fmt-${crypto.randomUUID()}`, text: "abcdef", textRuns: [{ start: 0, length: 4, styles: ["bold"] }, { start: 2, length: 2, effect: "nod" }] });
  check(overlap.error?.code === -32602, "overlapping textRuns rejected");
  const reformatted = await c.call("edit", { messageId: fmt.message.id, text: "hello again", textRuns: [{ start: 6, length: 5, styles: ["underline"] }] });
  check(JSON.stringify(reformatted.message.textRuns) === JSON.stringify([{ start: 6, length: 5, styles: ["underline"] }]), "edit replaces textRuns");
  const plain = await c.call("edit", { messageId: fmt.message.id, text: "hello plain" });
  check(plain.message.textRuns === undefined, "edit without textRuns clears formatting");
  let formattedSeen = false;
  for (let before: number | null = null, pages = 0; !formattedSeen && pages < 10; pages++) {
    const hp: any = await c.call("history", { beforeSeq: before, limit: 200 });
    formattedSeen = hp.messages.some((m: any) => m.id !== fmt.message.id && m.textRuns?.length);
    before = hp.messages[0].seq;
  }
  check(formattedSeen, "generated history includes formatted messages");

  console.log("link previews");
  const pr = (await c.call("unfurl", { url: "https://github.com/manaflow-ai/cmux/pull/123" })).linkPreview;
  check(pr.title === "Pull Request #123 · manaflow-ai/cmux" && pr.image.width === 1200 && pr.state === "loaded", "unfurl returns canned GitHub card");
  const og = await fetch(pr.image.url);
  const ogBytes = new Uint8Array(await og.arrayBuffer());
  check(og.ok && sniffImageSize(ogBytes)?.width === 1200, "preview image is served as a PNG at its size");
  const bare = (await c.call("unfurl", { url: "https://example.com/x" })).linkPreview;
  check(bare.url === "https://example.com/x" && !bare.title && !bare.image, "unknown URL unfurls to a bare card");
  check((await c.raw("unfurl", { url: "nope" })).error?.code === -32602, "unfurl rejects a non-http URL");
  const linkMsg = (await c.call("send", { clientMessageId: `l-${crypto.randomUUID()}`, text: "look https://www.apple.com/iphone/" })).message;
  check(linkMsg.linkPreview?.title?.startsWith("iPhone") && linkMsg.linkPreview.image.height === 630, "a trailing URL in a send carries a preview");
  const midMsg = (await c.call("send", { clientMessageId: `l-${crypto.randomUUID()}`, text: "see https://www.apple.com/iphone/ later" })).message;
  check(!midMsg.linkPreview, "a URL in the middle of text carries no preview");
  check(newest.messages.concat(older.messages).every((m: any) => !m.linkPreview || typeof m.linkPreview.url === "string"), "history previews are well formed");

  console.log("send effects");
  const fx = await c.call("send", { clientMessageId: `fx-${crypto.randomUUID()}`, text: "boom", effect: "slam" });
  check(fx.message.effect === "slam", "send with effect echoes effect");
  await c.waitFor(() => c.events().find((e) => e.kind === "message.created" && e.message.id === fx.message.id && e.message.effect === "slam"), 3000, "effect event");
  check(true, "message.created carries the effect");
  const badFx = await c.raw("send", { clientMessageId: `fx-${crypto.randomUUID()}`, text: "x", effect: "sparkle" });
  check(badFx.error?.code === -32602, "unknown effect is rejected");
  check(!s1.message.effect, "plain send has no effect");
  const said = await post("/admin/say?conversation=group&sender=leo&effect=balloons&text=happy%20birthday");
  check(said.message.senderId === "leo" && said.message.effect === "balloons" && said.message.text === "happy birthday", "admin say sends a bot message with an effect");
  await c.waitFor(() => c.events().find((e) => e.kind === "message.created" && e.message.id === said.message.id && e.message.effect === "balloons"), 3000, "say event");
  check(true, "admin say emits message.created with effect");
  const fxPage = await c.call("history", { beforeSeq: null, limit: 200 });
  check(fxPage.messages.every((m: any) => m.effect === undefined || typeof m.effect === "string"), "history carries effect strings");

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
    img = page.messages.flatMap((m: any) => m.attachments).find((a: any) => a.kind === "image");
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

  console.log("read state");
  const r1 = await Client.connect("group");
  const r2 = await Client.connect("group");
  await r1.call("hello", { clientId: "selftest-read-1" });
  await r2.call("hello", { clientId: "selftest-read-2" });
  const marked = await post("/admin/unread?conversation=group&count=25");
  check(marked.unreadCount === 25 && marked.lastReadSeq < marked.headSeq, "admin unread leaves exactly 25 messages from others unread");
  const seen = await r1.waitFor(() => r1.frames.find((f) => f.method === "readState" && f.params.unreadCount === 25), 3000, "readState 25");
  check(seen.params.lastReadSeq === marked.lastReadSeq, "readState notification carries the moved marker");
  const page = await r1.call("history", { beforeSeq: null, limit: 200 });
  const firstUnread = page.messages.find((m: any) => m.seq > marked.lastReadSeq && m.senderId !== "aziz");
  const lastOther = page.messages.filter((m: any) => m.senderId !== "aziz").at(-1);
  await r1.call("markRead", { upToSeq: firstUnread.seq });
  const partial = await r2.waitFor(() => r2.frames.find((f) => f.method === "readState" && f.params.lastReadSeq === firstUnread.seq), 3000, "partial readState on other device");
  check(partial.params.unreadCount === 24, "markRead through the first unread leaves 24, pushed to the other device");
  await r1.call("markRead", { upToSeq: marked.lastReadSeq });
  const stale = await fetch(base + "/admin/state").then((x) => x.json());
  check(stale.conversations.group.lastReadSeq === firstUnread.seq, "markRead never moves the marker backwards");
  await r2.call("markRead", { upToSeq: lastOther.seq });
  await r1.waitFor(() => r1.frames.find((f) => f.method === "readState" && f.params.unreadCount === 0), 3000, "readState 0");
  check(true, "reading to the newest clears unread on every device");
  await post("/admin/unread?conversation=group&count=4");
  await r1.call("send", { clientMessageId: `read-${crypto.randomUUID()}`, text: "caught up" });
  const afterSend = await fetch(base + "/admin/state").then((x) => x.json());
  check(afterSend.conversations.group.unreadCount === 0, "sending reads the conversation");
  r1.close();
  r2.close();
  console.log("audio");
  let aud: any;
  for (let before: number | null = null; !aud; ) {
    const page = await l.call("history", { beforeSeq: before, limit: 200 });
    // At least 2 s: the upload check below reuses its first 2 s of PCM.
    aud = page.messages.flatMap((m: any) => m.attachments).find((a: any) => a.kind === "audio" && a.durationMs >= 2000);
    before = page.messages[0].seq;
  }
  check(aud.durationMs > 1000 && aud.waveform.length >= 12 && aud.waveform.every((v: number) => v >= 0 && v <= 100), `history audio ${aud.durationMs}ms with ${aud.waveform.length}-level waveform`);
  check(typeof aud.transcript === "string" && aud.transcript.length > 0, "history audio carries a transcript");
  const wav = new Uint8Array(await (await fetch(aud.url)).arrayBuffer());
  const wavMs = (new DataView(wav.buffer).getUint32(40, true) / 32000) * 1000;
  check(String.fromCharCode(...wav.slice(0, 4)) === "RIFF" && Math.abs(wavMs - aud.durationMs) < 5, `GET ${new URL(aud.url).pathname} -> WAV of ${Math.round(wavMs)}ms`);
  // Bursts above pushed group's seeded tail away; direct still ends with history.
  const dc = await Client.connect("direct");
  await dc.call("hello", { clientId: "selftest-audio" });
  const recent = await dc.call("history", { beforeSeq: null, limit: 40 });
  dc.close();
  const recentAudio = recent.messages.filter((m: any) => m.attachments.some((a: any) => a.kind === "audio"));
  const pair = recent.messages.findIndex(
    (m: any, i: number) => i + 1 < recent.messages.length && m.senderId !== "aziz" && m.attachments[0]?.kind === "audio" && recent.messages[i + 1].attachments[0]?.kind === "audio" && recent.messages[i + 1].senderId === m.senderId,
  );
  check(pair >= 0 && recentAudio.some((m: any) => m.senderId === "aziz"), "newest page has two consecutive incoming recordings and one of mine");
  const myWav = new Uint8Array(wav.slice(0, 44 + 16000 * 2 * 2));
  new DataView(myWav.buffer).setUint32(40, 16000 * 2 * 2, true);
  const upa = await fetch(`${base}/upload?kind=audio&waveform=10,90,40`, { method: "POST", body: myWav, headers: { "content-type": "audio/wav", "x-transcript": encodeURIComponent("hi there") } }).then((x) => x.json());
  check(upa.attachment.kind === "audio" && upa.attachment.durationMs === 2000 && upa.attachment.waveform.join() === "10,90,40" && upa.attachment.transcript === "hi there", "audio upload reads WAV duration, waveform and transcript");
  const sentAudio = (await l.call("send", { clientMessageId: `aud-${crypto.randomUUID()}`, text: "", attachmentIds: [upa.attachment.id] })).message;
  check(sentAudio.attachments[0].kind === "audio" && sentAudio.attachments[0].expiresAt > Date.now(), "sent audio expires unless kept");
  const kept = (await l.call("keepAudio", { messageId: sentAudio.id })).message;
  check(kept.attachments[0].kept === true && kept.attachments[0].expiresAt === undefined, "keepAudio clears expiry");
  const adm = await post("/admin/audio?conversation=group&count=2");
  check(adm.messageIds.length === 2, "admin audio sends consecutive recordings");
  await l.waitFor(() => l.events().filter((e) => adm.messageIds.includes(e.message.id)).length >= 2, 3000, "admin audio events");
  await l.call("audioPlayed", { messageId: adm.messageIds[0] });
  await l.waitFor(() => l.events().find((e) => e.message.id === adm.messageIds[0] && e.message.attachments[0].expiresAt), 3000, "played expiry");
  check(true, "audioPlayed starts the expiry of an incoming recording");
  console.log("conversation list state");
  const ga = await Client.connect("group");
  const gh = await ga.call("hello", { clientId: "list-a" });
  check(
    gh.conversation.pinned === false && gh.conversation.muted === false && gh.conversation.markedUnread === false && gh.conversation.deleted === false && !("pinOrder" in gh.conversation),
    "hello carries default list state (unpinned, alerts on, read, not deleted)",
  );
  const gb = await Client.connect("group");
  await gb.call("hello", { clientId: "list-b" });
  const pinned = await ga.call("updateConversation", { pinned: true });
  check(pinned.conversation.pinned === true && pinned.conversation.pinOrder === 0, "pin returns pinned with pinOrder 0");
  const pushed = await gb.waitFor(() => gb.frames.find((f) => f.method === "conversation" && f.params.conversation.pinned), 3000, "conversation push");
  check(pushed.params.conversation.id === "group", "pin is pushed to the conversation's other clients");
  const da = await Client.connect("direct");
  await da.call("hello", { clientId: "list-d" });
  const overLimit = await da.raw("updateConversation", { pinned: true });
  check(overLimit.error?.code === -32004, "pinning past MAX_PINNED is rejected (-32004 pin limit)");
  const badType = await da.raw("updateConversation", { muted: "yes" });
  check(badType.error?.code === -32602, "non-boolean list field is rejected (-32602)");
  const muted = await ga.call("updateConversation", { muted: true, markedUnread: true });
  check(muted.conversation.muted === true && muted.conversation.markedUnread === true && muted.conversation.pinned === true, "Hide Alerts and Mark as Unread apply without touching the pin");
  const deleted = await ga.call("updateConversation", { deleted: true });
  check(
    deleted.conversation.deleted === true && deleted.conversation.pinned === false && !("pinOrder" in deleted.conversation) && deleted.conversation.markedUnread === false && deleted.conversation.muted === true,
    "delete unpins and clears Mark as Unread, keeps Hide Alerts",
  );
  const pinDirect = await da.call("updateConversation", { pinned: true });
  check(pinDirect.conversation.pinned === true, "deleting a pinned conversation frees its pin slot");
  await da.call("updateConversation", { pinned: false });
  gb.frames = [];
  await post("/admin/burst?conversation=group&count=1&intervalMs=0");
  await gb.waitFor(() => gb.frames.find((f) => f.method === "conversation" && f.params.conversation.deleted === false), 3000, "undelete push");
  check(true, "a new incoming message brings a deleted conversation back");
  const rehello = await (await Client.connect("group")).call("hello", { clientId: "list-c" });
  check(rehello.conversation.deleted === false && rehello.conversation.muted === true, "hello after reconnect carries the current list state");
  await ga.call("updateConversation", { muted: false });
  check(gh.conversation.sendReadReceipts === true, "hello carries Send Read Receipts on by default");
  const receiptsOff = await ga.call("updateConversation", { sendReadReceipts: false });
  check(receiptsOff.conversation.sendReadReceipts === false && receiptsOff.conversation.muted === false, "Send Read Receipts turns off without touching Hide Alerts");
  const beforeOff = (await getState()).conversations.group.receiptSeq;
  await post("/admin/burst?conversation=group&count=1&intervalMs=0");
  const quietHead = (await getState()).conversations.group.headSeq;
  await ga.call("markRead", { upToSeq: quietHead });
  const receiptState = (await getState()).conversations.group;
  check(receiptState.lastReadSeq === quietHead && receiptState.receiptSeq === beforeOff, "markRead with receipts off reads without telling others");
  await ga.call("updateConversation", { sendReadReceipts: true });
  await post("/admin/burst?conversation=group&count=1&intervalMs=0");
  const loudHead = (await getState()).conversations.group.headSeq;
  await ga.call("markRead", { upToSeq: loudHead });
  check((await getState()).conversations.group.receiptSeq === loudHead, "markRead with receipts on sends the receipt");
  ga.close();
  gb.close();
  da.close();
  console.log("polls");
  // Deterministic votes; the failure knob is exercised explicitly below.
  await post("/admin/knobs", { pollVoteFailRate: 0 });
  const pollSend = await l.call("send", { clientMessageId: `poll-${crypto.randomUUID()}`, text: "", poll: { question: " Lunch? ", options: ["Tacos", " ", "Ramen"] } });
  const pm = pollSend.message;
  check(pm.text === "Lunch?" && pm.poll?.question === "Lunch?" && pm.poll.options.map((o: any) => o.id).join() === "o1,o2", "send with poll creates a poll message (blank choices dropped)");
  const badPoll = await l.raw("send", { clientMessageId: `poll-${crypto.randomUUID()}`, text: "", poll: { question: "q", options: ["only"] } });
  check(badPoll.error?.code === -32602, "a poll with fewer than 2 choices is rejected");
  const v1 = await l.call("votePoll", { messageId: pm.id, optionId: "o1", selected: true });
  const v2 = await l.call("votePoll", { messageId: pm.id, optionId: "o2", selected: true });
  const mine = (m: any) => m.poll.votes.filter((v: any) => v.participantId === "aziz").map((v: any) => v.optionId).sort().join();
  check(mine(v1.message) === "o1" && mine(v2.message) === "o1,o2", "votePoll is multi-select");
  const v3 = await l.call("votePoll", { messageId: pm.id, optionId: "o1", selected: false });
  check(mine(v3.message) === "o2", "votePoll selected=false takes the vote back");
  const added = await l.call("addPollOption", { messageId: pm.id, text: "Sushi" });
  check(added.message.poll.options.at(-1).id === "o3" && added.message.poll.options.at(-1).addedBy === "aziz", "addPollOption appends a choice with addedBy");
  const badVote = await l.raw("votePoll", { messageId: pm.id, optionId: "o9", selected: true });
  check(badVote.error?.code === -32602, "voting for an unknown choice is rejected");
  const pollEdit = await l.raw("edit", { messageId: pm.id, text: "x" });
  check(pollEdit.error?.code === -32602, "polls cannot be edited");
  await post("/admin/knobs", { pollVoteFailRate: 1 });
  const vf = await l.raw("votePoll", { messageId: pm.id, optionId: "o1", selected: true });
  check(vf.error?.code === -32004 && vf.error.message === "vote not delivered", "pollVoteFailRate=1 -> -32004 vote not delivered");
  await post("/admin/knobs", { pollVoteFailRate: 0 });
  await post("/admin/knobs", { botIntervalScale: 0.05 }); // let bots act briefly
  const adminPoll = await post("/admin/poll?conversation=group&question=Ship%3F&options=Yes,No");
  check(adminPoll.message.poll.options.length === 2 && adminPoll.message.senderId !== "aziz", "/admin/poll makes a bot post a poll");
  await l.waitFor(
    () => l.events().find((e) => e.message.id === adminPoll.message.id && e.message.poll.votes.some((v: any) => v.participantId !== "aziz")),
    5000,
    "bot votes",
  );
  check(true, "bots vote on a new poll with live message.updated events");
  await post("/admin/knobs", { botIntervalScale: 10000 });
  let historyPoll: any;
  for (let before: number | null = null; !historyPoll && before !== 1; ) {
    const page = await l.call("history", { beforeSeq: before, limit: 200 });
    historyPoll = page.messages.find((m: any) => m.poll && m.seq < pm.seq - 600);
    before = page.messages[0].seq;
  }
  check(historyPoll?.poll.options.length >= 2 && historyPoll.text === historyPoll.poll.question, "seeded history contains polls");
  console.log("send later");
  const savedKnobs = await fetch(base + "/admin/knobs").then((x) => x.json());
  await post("/admin/knobs", { failRate: 0, scheduledFailRate: 0 });
  const sc = await Client.connect("group");
  await sc.call("hello", { clientId: "selftest-sched" });
  const schedCmid = `sched-${crypto.randomUUID()}`;
  const later = Date.now() + 3600_000;
  const sch = (await sc.call("scheduleSend", { clientMessageId: schedCmid, text: "later", scheduledAt: later })).scheduled;
  check(sch.id.startsWith("sched_group_") && sch.clientMessageId === schedCmid && sch.state === "scheduled" && sch.scheduledAt === later && sch.seq === undefined, "scheduleSend returns a scheduled message without seq");
  await sc.waitFor(() => sc.events().find((e) => e.kind === "scheduled.upserted" && e.scheduled.id === sch.id), 3000, "scheduled.upserted");
  check(true, "scheduled.upserted event received");
  const schAgain = (await sc.call("scheduleSend", { clientMessageId: schedCmid, text: "later", scheduledAt: later })).scheduled;
  check(schAgain.id === sch.id, "scheduleSend idempotent on clientMessageId");
  const tooFar = await sc.raw("scheduleSend", { clientMessageId: `x-${crypto.randomUUID()}`, text: "x", scheduledAt: Date.now() + 15 * 24 * 3600_000 });
  const past = await sc.raw("scheduleSend", { clientMessageId: `x-${crypto.randomUUID()}`, text: "x", scheduledAt: Date.now() - 60_000 });
  check(tooFar.error?.code === -32602 && past.error?.code === -32602, "scheduledAt beyond 14 days or in the past is rejected");
  const listed = (await sc.call("scheduled")).scheduled;
  check(listed.some((x: any) => x.id === sch.id), "scheduled lists it");
  const hist = await sc.call("history", { beforeSeq: null, limit: 20 });
  check(!hist.messages.some((m: any) => m.clientMessageId === schedCmid), "scheduled message is not in history");
  const later2 = later + 600_000;
  const resch = (await sc.call("reschedule", { id: sch.id, scheduledAt: later2 })).scheduled;
  check(resch.scheduledAt === later2, "reschedule changes the time");
  await sc.call("cancelScheduled", { id: sch.id });
  await sc.waitFor(() => sc.events().find((e) => e.kind === "scheduled.removed" && e.id === sch.id && e.reason === "cancelled" && e.clientMessageId === schedCmid), 3000, "cancel event");
  check(!(await sc.call("scheduled")).scheduled.some((x: any) => x.id === sch.id), "cancelScheduled removes it (event reason cancelled)");
  const badCancel = await sc.raw("cancelScheduled", { id: sch.id });
  check(badCancel.error?.code === -32602, "cancelling an unknown id is rejected");

  const dueCmid = `due-${crypto.randomUUID()}`;
  const due = (await sc.call("scheduleSend", { clientMessageId: dueCmid, text: "due soon", scheduledAt: Date.now() + 1500 })).scheduled;
  const created = await sc.waitFor(() => sc.events().find((e) => e.kind === "message.created" && e.message.clientMessageId === dueCmid), 5000, "fired message");
  check(created.message.seq > 0 && created.message.text === "due soon" && created.message.senderId === "aziz", "due scheduled message becomes a normal message with the same clientMessageId");
  const removed = await sc.waitFor(() => sc.events().find((e) => e.kind === "scheduled.removed" && e.id === due.id), 3000, "sent removal");
  check(removed.reason === "sent" && removed.messageId === created.message.id && removed.eventSeq > created.eventSeq, "scheduled.removed(sent) follows message.created with messageId");
  const resent = await sc.raw("scheduleSend", { clientMessageId: dueCmid, text: "due soon", scheduledAt: Date.now() + 60_000 });
  check(resent.error?.code === -32602, "scheduleSend with an already-sent clientMessageId is rejected");
  const sendDup = await sc.call("send", { clientMessageId: dueCmid, text: "due soon" });
  check(sendDup.message.id === created.message.id, "send with the fired clientMessageId returns the fired message");

  const nowCmid = `now-${crypto.randomUUID()}`;
  const toNow = (await sc.call("scheduleSend", { clientMessageId: nowCmid, text: "send me now", scheduledAt: Date.now() + 3600_000 })).scheduled;
  const sentNow = (await sc.call("sendScheduledNow", { id: toNow.id })).message;
  check(sentNow.clientMessageId === nowCmid && sentNow.seq > 0, "sendScheduledNow returns the sent message");
  check(!(await sc.call("scheduled")).scheduled.some((x: any) => x.id === toNow.id), "sendScheduledNow removes it from the list");

  await post("/admin/knobs", { scheduledFailRate: 1 });
  const failCmid = `fail-${crypto.randomUUID()}`;
  const willFail = (await sc.call("scheduleSend", { clientMessageId: failCmid, text: "will fail", scheduledAt: Date.now() + 500 })).scheduled;
  const failedEv = await sc.waitFor(() => sc.events().find((e) => e.kind === "scheduled.upserted" && e.scheduled.id === willFail.id && e.scheduled.state === "failed"), 5000, "failed scheduled");
  check(failedEv.scheduled.error === "not delivered", "scheduledFailRate=1: due message becomes state failed");
  await sleep(600);
  const stillListed = (await sc.call("scheduled")).scheduled.find((x: any) => x.id === willFail.id);
  check(stillListed?.state === "failed" && !sc.events().some((e) => e.kind === "message.created" && e.message.clientMessageId === failCmid), "failed scheduled message stays listed and is not re-fired");
  await post("/admin/knobs", { scheduledFailRate: 0 });
  const retried = (await sc.call("sendScheduledNow", { id: willFail.id })).message;
  check(retried.clientMessageId === failCmid && retried.seq > 0, "sendScheduledNow sends a failed scheduled message");
  const fmtSched = (await sc.call("scheduleSend", {
    clientMessageId: `sf-${crypto.randomUUID()}`, text: "hey Leo look", scheduledAt: Date.now() + 3600_000,
    mentions: [{ participantId: "leo", location: 4, length: 3 }], textRuns: [{ start: 8, length: 4, styles: ["bold"] }], effect: "gentle",
  })).scheduled;
  check(fmtSched.mentions?.length === 1 && fmtSched.textRuns?.length === 1 && fmtSched.effect === "gentle", "scheduleSend keeps mentions, formatting and effect");
  const firedFmt = await post(`/admin/scheduled/fire?conversation=group&id=${fmtSched.id}`);
  const firedMsg = (await sc.call("history", { beforeSeq: null, limit: 20 })).messages.find((m: any) => m.id === firedFmt.messageId);
  check(firedMsg?.mentions?.[0]?.participantId === "leo" && firedMsg?.textRuns?.[0]?.styles?.[0] === "bold" && firedMsg?.effect === "gentle", "a fired scheduled message carries them");
  const sr2 = (await sc.call("scheduleSend", { clientMessageId: `r-${crypto.randomUUID()}`, text: "x", scheduledAt: Date.now() + 3600_000 })).scheduled;
  const state = await fetch(base + "/admin/state").then((x) => x.json());
  check(state.conversations.group.scheduled >= 1, "/admin/state counts scheduled messages");
  await sc.call("cancelScheduled", { id: sr2.id });
  sc.close();
  await post("/admin/knobs", { failRate: savedKnobs.failRate, scheduledFailRate: savedKnobs.scheduledFailRate });
  console.log("new message: contacts, lookup, create");
  {
    const c = await Client.connect("group");
    await c.call("hello", { clientId: "compose" });
    const ka = await c.call("searchContacts", { query: "ka" });
    check(ka.contacts[0]?.name === "Kate Bell" && ka.contacts[0].handles.length === 2, "searchContacts 'ka' -> Kate Bell first, with handles");
    const ha = await c.call("searchContacts", { query: "ha" });
    check(ha.contacts.map((x: any) => x.name).join("|") === "Hank M. Zakroff|Anna Haro", "name prefix ranks before a later-word prefix");
    const ex = await c.call("searchContacts", { query: "ha", excludeIds: ["hank"] });
    check(ex.contacts.length === 1 && ex.contacts[0].id === "anna", "excludeIds drops already-added recipients");
    const byPhone = await c.call("searchContacts", { query: "564-85" });
    check(byPhone.contacts[0]?.id === "kate", "handle substring matches");
    const all = await c.call("searchContacts", { query: "  ", limit: 50, excludeIds: ["kate"] });
    check(all.contacts.length === 8 && all.contacts[0].name === "Anna Haro" && !all.contacts.some((x: any) => x.id === "kate"), "blank query lists every contact alphabetically, minus excludeIds");
    const look = await c.call("lookupHandles", { handles: ["kate-bell@mac.com", "+1 555 766 4823", "someone@example.com", "(555) 123-4567", "Apple"] });
    check(
      look.results.map((r: any) => `${r.service}:${r.contact?.id ?? "-"}`).join(",") === "iMessage:kate,SMS:hank,iMessage:-,SMS:-,null:-",
      "lookupHandles reports service per address, contact when known, null when invalid",
    );
    const direct = await c.call("createConversation", { recipients: [{ participantId: "john" }] });
    check(direct.created === false && direct.conversation.id === "direct", "creating with John opens the existing 1:1");
    const group = await c.call("createConversation", { recipients: [{ participantId: "leo" }, { participantId: "lawrence" }, { participantId: "austin" }, { participantId: "aziz" }] });
    check(group.created === false && group.conversation.id === "group", "same members in any order (me ignored) open the existing group");
    const fresh = await c.call("createConversation", { recipients: [{ participantId: "kate" }, { handle: "kate-bell@mac.com" }, { handle: "+1 555 766 4823" }] });
    check(fresh.created === true && fresh.conversation.kind === "group" && fresh.conversation.participants.length === 3, "new group dedupes a contact given by id and by handle");
    check(fresh.conversation.title === "Kate & Hank" && fresh.conversation.service === "SMS", "group title from first names; any SMS member makes it SMS");
    const again = await c.call("createConversation", { recipients: [{ handle: "+1 (555) 766-4823" }, { participantId: "kate" }] });
    check(again.created === false && again.conversation.id === fresh.conversation.id, "creating the same group again reopens it");
    const raw = await c.call("createConversation", { recipients: [{ handle: "(555) 123-4567" }] });
    check(raw.created === true && raw.conversation.kind === "direct" && raw.conversation.title === "(555) 123-4567", "unknown phone number makes an SMS 1:1 titled by the number");
    const bad = await c.raw("createConversation", { recipients: [{ handle: "Apple" }] });
    check(bad.error?.code === -32005, "invalid address -> -32005");
    c.close();
    const n = await Client.connect(fresh.conversation.id);
    const nh = await n.call("hello", { clientId: "compose-2" });
    check(nh.conversation.id === fresh.conversation.id && nh.headSeq === 0, "the created conversation is reachable over /ws and starts empty");
    const first = await n.call("send", { clientMessageId: `first-${crypto.randomUUID()}`, text: "hi both" });
    check(first.message.seq === 1, "first send starts the conversation at seq 1");
    n.close();
  }

  console.log("group status rows");
  const sg = await Client.connect("group");
  await sg.call("hello", { clientId: "status-g" });
  const top = await sg.call("history", { beforeSeq: 2, limit: 1 });
  check(top.messages[0].seq === 1 && top.messages[0].system?.kind === "named" && top.messages[0].system.name === "cmux" && top.messages[0].text === "", "history opens with the group being named");
  await post("/admin/unread?conversation=group&count=0");
  const left = await post("/admin/system?conversation=group&kind=left&actor=leo");
  check(left.message.system.kind === "left" && left.message.senderId === "leo", "admin system posts a status row from its actor");
  await sg.waitFor(() => sg.frames.find((f) => f.method === "conversation" && f.params.conversation.participants.find((p: any) => p.id === "leo")?.left === true), 3000, "left push");
  check(true, "leaving marks the member left in a conversation push");
  const state1 = await fetch(base + "/admin/state").then((r) => r.json());
  check(state1.conversations.group.unreadCount === 0, "status rows never count as unread");
  const badAdd = await fetch(base + "/admin/system?conversation=group&kind=added&actor=leo&target=austin", { method: "POST" });
  check(badAdd.status === 400, "a member who left cannot act, and only former members can be added");
  await post("/admin/system?conversation=group&kind=added&actor=lawrence&target=leo");
  const renamed = await post("/admin/system?conversation=group&kind=named&actor=austin&name=" + encodeURIComponent("ship it"));
  check(renamed.conversation.title === "ship it", "naming the conversation changes its title");
  await sg.waitFor(() => sg.events().find((e) => e.message.id === renamed.message.id && e.message.system?.name === "ship it"), 3000, "named event");
  await post("/admin/system?conversation=group&kind=named&actor=austin&name=cmux");
  const directStatus = await fetch(base + "/admin/system?conversation=direct&kind=changedPhoto&actor=john", { method: "POST" });
  check(directStatus.status === 400, "status rows are for group conversations");
  sg.close();

  console.log("Focus: Delivered Quietly and Notify Anyway");
  const fd = await Client.connect("direct");
  await fd.call("hello", { clientId: "focus-d" });
  await post("/admin/focus?conversation=direct&on=1");
  await fd.waitFor(() => fd.frames.find((f) => f.method === "conversation" && f.params.conversation.participants.find((p: any) => !p.isMe)?.notificationsSilenced === true), 3000, "silenced push");
  check(true, "Focus on pushes notificationsSilenced");
  const quiet = (await fd.call("send", { clientMessageId: `quiet-${crypto.randomUUID()}`, text: "are you around?" })).message;
  await fd.waitFor(() => fd.events().find((e) => e.message.id === quiet.id && e.message.status === "delivered" && e.message.deliveredQuietly === true), 5000, "delivered quietly");
  check(true, "a message delivered while silenced is Delivered Quietly");
  const notified = await fd.call("notifyAnyway", { messageId: quiet.id });
  check(notified.message.notifiedAnyway === true, "notifyAnyway marks the message");
  const notQuiet = await fd.raw("notifyAnyway", { messageId: top.messages[0].id });
  check(notQuiet.error?.code === -32602, "notifyAnyway refuses anything but my quietly delivered message");
  await post("/admin/focus?conversation=direct&on=0");
  const loud = (await fd.call("send", { clientMessageId: `loud-${crypto.randomUUID()}`, text: "ok" })).message;
  await fd.waitFor(() => fd.events().find((e) => e.message.id === loud.id && e.message.status === "delivered"), 5000, "delivered");
  check(!fd.events().some((e) => e.message.id === loud.id && e.message.deliveredQuietly), "Focus off delivers normally");
  fd.close();

  console.log("empty conversation");
  const ec = await Client.connect("empty");
  const eh = await ec.call("hello", { clientId: "empty" });
  check(eh.headSeq === 0 && eh.unreadCount === 0 && eh.conversation.kind === "direct", "the empty conversation has no messages");
  const eHistory = await ec.call("history", { beforeSeq: null, limit: 50 });
  check(eHistory.messages.length === 0 && eHistory.hasMore === false, "its history is empty and exhausted");
  ec.close();

  console.log("backgrounds");
  const ba = await Client.connect("direct");
  const bb = await Client.connect("direct");
  const bh = await ba.call("hello", { clientId: "bg-a" });
  await bb.call("hello", { clientId: "bg-b" });
  check(!("background" in bh.conversation), "a conversation starts without a background");
  const bgUnreadBefore = bh.unreadCount;
  const setLook = await ba.call("setBackground", { background: { kind: "sky", look: "sky.dusk" } });
  const sky = setLook.conversation.background;
  check(
    sky.kind === "sky" && sky.look === "sky.dusk" && sky.colors.length === 3 && sky.setBy === "aziz" && sky.luminance > 0 && sky.luminance < 0.18 && typeof sky.id === "string",
    `setBackground with a preset fills its colors and luminance (L=${sky.luminance})`,
  );
  const bgPushed = await bb.waitFor(() => bb.frames.find((f) => f.method === "conversation" && f.params.conversation.background?.id === sky.id), 3000, "background push");
  check(bgPushed.params.conversation.background.look === "sky.dusk", "the other device receives the background");
  const notice = await bb.waitFor(() => bb.events().find((e) => e.kind === "message.created" && e.message.system?.kind === "changedBackground"), 3000, "background notice");
  check(notice.message.senderId === "aziz" && notice.message.text === "" && !notice.message.status, "setting writes a system line by me, with no delivery status");
  const solid = await ba.call("setBackground", { background: { kind: "color", colors: ["#ffffff"] } });
  check(solid.conversation.background.colors[0] === "#FFFFFF" && solid.conversation.background.luminance === 1, "a solid color derives its luminance");
  check((await ba.raw("setBackground", { background: { kind: "color", colors: ["red"] } })).error?.code === -32602, "malformed colors are rejected");
  check((await ba.raw("setBackground", { background: { kind: "neon" } })).error?.code === -32602, "unknown kinds are rejected");
  check((await ba.raw("setBackground", { background: { kind: "photo", luminance: 0.4 } })).error?.code === -32602, "a photo needs an uploaded attachment");
  const bgUp = await fetch(`${base}/upload`, { method: "POST", headers: { "content-type": "image/png" }, body: proceduralPNG("bg-upload", 300, 600) }).then((r) => r.json());
  check((await ba.raw("setBackground", { background: { kind: "photo", attachmentId: bgUp.attachment.id } })).error?.code === -32602, "a photo needs its luminance");
  const photo = await ba.call("setBackground", { background: { kind: "photo", attachmentId: bgUp.attachment.id, luminance: 0.42 } });
  check(
    photo.conversation.background.photo.url.endsWith(`/media/${bgUp.attachment.id}.png`) && photo.conversation.background.photo.width === bgUp.attachment.width && photo.conversation.background.luminance === 0.42,
    "a photo background carries the uploaded image and its luminance",
  );
  const cleared = await ba.call("setBackground", { background: null });
  check(!("background" in cleared.conversation), "setBackground null removes it");
  await bb.waitFor(() => bb.events().find((e) => e.kind === "message.created" && e.message.system?.kind === "removedBackground"), 3000, "removed notice");
  check(true, "removing writes a 'removed the background' line");
  const bgEventsBefore = ba.events().length;
  await ba.call("setBackground", { background: null });
  await sleep(200);
  check(!ba.events().slice(bgEventsBefore).some((e) => e.message.system), "removing when there is none writes nothing");
  const byBot = await post("/admin/background?conversation=direct&sender=john&look=glitter.gold");
  check(byBot.conversation.background.kind === "glitter" && byBot.conversation.background.setBy === "john", "admin background: John sets Glitter");
  check(byBot.conversation.background.luminance < 0.18, `Glitter is as dark as its base, not the mean of its sparkle colors (L=${byBot.conversation.background.luminance})`);
  const botNotice = await ba.waitFor(() => ba.events().find((e) => e.message.system?.kind === "changedBackground" && e.message.senderId === "john"), 3000, "bot notice");
  const afterBot = await ba.call("hello", { clientId: "bg-a2" });
  check(afterBot.unreadCount === bgUnreadBefore && afterBot.conversation.background.setBy === "john", "a system line from someone else is not unread; hello carries the background");
  const botPhoto = await post("/admin/background?conversation=direct&sender=john&kind=photo");
  const bp = botPhoto.conversation.background;
  const bpBytes = new Uint8Array(await (await fetch(bp.photo.url)).arrayBuffer());
  check(bp.kind === "photo" && sniffImageSize(bpBytes)?.height === 1200 && bp.luminance > 0 && bp.luminance < 1, `a bot photo background is served with its luminance (L=${bp.luminance})`);
  const bgPage = await ba.call("history", { beforeSeq: null, limit: 10 });
  check(bgPage.messages.some((m: any) => m.id === botNotice.message.id && m.system?.kind === "changedBackground"), "history carries system lines");
  await post("/admin/background?conversation=direct&clear=1&sender=john");
  ba.close();
  bb.close();

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
