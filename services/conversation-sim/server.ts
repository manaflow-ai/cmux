// conversation-sim: long-running fake remote chat service. See PROTOCOL.md.
// Run: bun run services/conversation-sim/server.ts  (PORT, HOST, SEED, LOG=verbose)
import type { ServerWebSocket } from "bun";
import { mulberry32, proceduralPNG, sniffImageSize } from "./png";
import { editedText, imageSize, messageText, pick, randInt, replyText, type Rng } from "./corpus";

// ---------------------------------------------------------------- types

type Reaction = "heart" | "thumbsup" | "thumbsdown" | "haha" | "exclamation" | "question";
const REACTIONS: Reaction[] = ["heart", "thumbsup", "thumbsdown", "haha", "exclamation", "question"];

interface Participant {
  id: string;
  name: string;
  initials: string;
  colorHex: string;
  isMe: boolean;
}
interface Conversation {
  id: string;
  title: string;
  kind: "group" | "direct";
  participants: Participant[];
}
interface AttachmentRef {
  id: string;
  kind: "image";
  width: number;
  height: number;
}
interface Message {
  id: string;
  seq: number;
  clientMessageId?: string;
  senderId: string;
  sentAt: number;
  text: string;
  replyToId?: string;
  replyCount: number;
  editedAt?: number;
  reactions: { participantId: string; reaction: Reaction }[];
  attachments: AttachmentRef[];
  status?: "sent" | "delivered" | "read";
  readAt?: number;
}
interface LoggedEvent {
  eventSeq: number;
  kind: "message.created" | "message.updated";
  message: Message; // snapshot at append time
}
interface MediaEntry {
  width: number;
  height: number;
  ext: string;
  mime: string;
  bytes?: Uint8Array; // uploads only; procedural images are generated on demand
}

// ---------------------------------------------------------------- config

const PORT = Number(process.env.PORT ?? 4870);
const HOST = process.env.HOST ?? "0.0.0.0";
const SEED = Number(process.env.SEED ?? 1337);
const VERBOSE = process.env.LOG === "verbose";
const EVENT_LOG_CAP = Number(process.env.EVENT_LOG_CAP ?? 50_000);
const REPLAY_LIMIT = 500;
const GROUP_COUNT = Number(process.env.GROUP_MESSAGES ?? 20_000);
const DIRECT_COUNT = Number(process.env.DIRECT_MESSAGES ?? 5_000);

const knobs = {
  latencyScale: 1,
  failRate: 0.04,
  historyFailRate: 0.07,
  duplicateRate: 0.02,
  disconnectEverySeconds: 240,
  botIntervalScale: 1,
};
type Knobs = typeof knobs;

const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);
const vlog = (line: string) => VERBOSE && log(line);

const R: Rng = Math.random; // live traffic randomness (not seeded)
const uniform = (lo: number, hi: number, rng: Rng = R) => lo + rng() * (hi - lo);
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, Math.max(0, ms)));
const lat = (lo: number, hi: number) => uniform(lo, hi) * knobs.latencyScale;

/** Sleep that tracks live changes to botIntervalScale (progress advances at 1/scale). */
async function botSleep(baseMs: number) {
  let progress = 0;
  const tick = 200;
  while (progress < baseMs) {
    await sleep(tick);
    progress += tick / Math.max(0.01, knobs.botIntervalScale);
  }
}

function lognormalHistoryDelay(): number {
  // median 1.1 s, clamped to [0.4, 4] s
  const z = Math.sqrt(-2 * Math.log(1 - R())) * Math.cos(2 * Math.PI * R());
  const s = Math.min(4, Math.max(0.4, Math.exp(Math.log(1.1) + 0.5 * z)));
  return s * 1000 * knobs.latencyScale;
}

// ---------------------------------------------------------------- participants

const ME: Participant = { id: "aziz", name: "Aziz Albahar", initials: "AA", colorHex: "#0A84FF", isMe: true };
const LAWRENCE: Participant = { id: "lawrence", name: "Lawrence Chen", initials: "LC", colorHex: "#FF9F0A", isMe: false };
const AUSTIN: Participant = { id: "austin", name: "Austin Wang", initials: "AW", colorHex: "#30D158", isMe: false };
const LEO: Participant = { id: "leo", name: "Leo Li", initials: "LL", colorHex: "#BF5AF2", isMe: false };
const JOHN: Participant = { id: "john", name: "John Appleseed", initials: "JA", colorHex: "#FF375F", isMe: false };

// ---------------------------------------------------------------- store

const media = new Map<string, MediaEntry>();

class Store {
  messages: Message[] = []; // index = seq - 1
  byId = new Map<string, Message>();
  byClientId = new Map<string, Message>();
  events: LoggedEvent[] = [];
  headEventSeq = 0;
  conns = new Set<Conn>();
  lastReadSeq = 0;
  constructor(public conv: Conversation) {}

  get headSeq() {
    return this.messages.length;
  }
  get oldestEventSeq() {
    return this.events.length ? this.events[0].eventSeq : this.headEventSeq + 1;
  }
  bots() {
    return this.conv.participants.filter((p) => !p.isMe);
  }

  append(msg: Omit<Message, "id" | "seq">): Message {
    const seq = this.messages.length + 1;
    const m: Message = { id: `${this.conv.id}_${seq}`, seq, ...msg };
    this.messages.push(m);
    this.byId.set(m.id, m);
    if (m.clientMessageId) this.byClientId.set(m.clientMessageId, m);
    return m;
  }

  emit(kind: LoggedEvent["kind"], message: Message) {
    const ev: LoggedEvent = { eventSeq: ++this.headEventSeq, kind, message: structuredClone(message) };
    this.events.push(ev);
    if (this.events.length > EVENT_LOG_CAP) this.events.splice(0, this.events.length - EVENT_LOG_CAP);
    for (const c of this.conns) if (c.subscribed) c.pushEvent(ev);
  }

  broadcastTyping(participantId: string, isTyping: boolean) {
    for (const c of this.conns) if (c.subscribed) c.notify("typing", { participantId, isTyping }, true);
  }

  /** Create a message from anyone, emitting created plus parent reply-count update. */
  create(senderId: string, text: string, opts: Partial<Message> = {}): Message {
    const isMe = senderId === ME.id;
    const m = this.append({
      senderId,
      sentAt: Date.now(),
      text,
      replyCount: 0,
      reactions: [],
      attachments: [],
      ...opts,
      ...(isMe ? { status: opts.status ?? "sent" } : {}),
    });
    this.emit("message.created", m);
    if (m.replyToId) {
      const parent = this.byId.get(m.replyToId);
      if (parent) {
        parent.replyCount++;
        this.emit("message.updated", parent);
      }
    }
    return m;
  }
}

// ---------------------------------------------------------------- history

function generateHistory(store: Store, total: number, meShare: number, seed: number) {
  const rng = mulberry32(seed);
  const conv = store.conv;
  const others = conv.participants.filter((p) => !p.isMe);
  const now = Date.now();
  const DAYS = 90;
  const day0 = new Date(now);
  day0.setHours(0, 0, 0, 0);
  day0.setDate(day0.getDate() - DAYS);

  // Active-day mask: weekends quieter, a couple of multi-day quiet streaks.
  const active: boolean[] = [];
  for (let d = 0; d <= DAYS; d++) {
    const date = new Date(day0);
    date.setDate(day0.getDate() + d);
    const weekend = date.getDay() === 0 || date.getDay() === 6;
    active.push(rng() < (weekend ? 0.5 : 0.92));
  }
  for (let k = 0; k < 3; k++) {
    const start = randInt(rng, 5, DAYS - 10);
    const len = randInt(rng, 2, 4);
    for (let d = start; d < start + len; d++) active[d] = false;
  }
  const todayIdx = DAYS;
  const nowDate = new Date(now);
  const nowHours = nowDate.getHours() + nowDate.getMinutes() / 60;
  active[todayIdx] = nowHours > 9.5;
  if (!active[todayIdx]) active[todayIdx - 1] = true;

  const weights = active.map((a) => (a ? 0.3 + rng() * 1.7 : 0));
  const wsum = weights.reduce((a, b) => a + b, 0);
  const counts = weights.map((w) => Math.floor((total * w) / wsum));
  let remainder = total - counts.reduce((a, b) => a + b, 0);
  for (let d = DAYS; remainder > 0; d = (d + DAYS) % (DAYS + 1)) {
    if (active[d]) {
      counts[d]++;
      remainder--;
    }
  }

  type Draft = Omit<Message, "id" | "seq"> & { day: number; replyToIndex?: number };
  const drafts: Draft[] = [];
  for (let d = 0; d <= DAYS; d++) {
    const c = counts[d];
    if (!c) continue;
    const dayStart = new Date(day0);
    dayStart.setDate(day0.getDate() + d);
    const base = dayStart.getTime();
    const windowStart = 8.5;
    const windowEnd = d === todayIdx ? Math.max(windowStart + 0.5, nowHours - 0.3) : 23.5;
    const sessions = Math.min(10, Math.max(1, Math.ceil(c / 40)));
    const starts = Array.from({ length: sessions }, () => uniform(windowStart, windowEnd, rng)).sort((a, b) => a - b);
    let left = c;
    let prevSender = pick(rng, conv.participants).id;
    for (let s = 0; s < sessions; s++) {
      const n = s === sessions - 1 ? left : Math.max(1, Math.round((left / (sessions - s)) * uniform(0.5, 1.5, rng)));
      left -= n;
      let t = base + starts[s] * 3600_000;
      for (let i = 0; i < n; i++) {
        t += 2000 + rng() * rng() * 150_000;
        let sender: string;
        if (rng() < 0.35) sender = prevSender;
        else sender = rng() < meShare ? ME.id : pick(rng, others).id;
        prevSender = sender;
        drafts.push({ day: d, senderId: sender, sentAt: Math.round(t), text: "", replyCount: 0, reactions: [], attachments: [] });
      }
    }
  }
  drafts.sort((a, b) => a.sentAt - b.sentAt);
  const cap = now - 60_000;
  // Keep strictly increasing timestamps that never exceed "now".
  for (let i = drafts.length - 1; i >= 0; i--) {
    const limit = i === drafts.length - 1 ? cap : drafts[i + 1].sentAt - 1;
    if (drafts[i].sentAt > limit) drafts[i].sentAt = limit;
  }
  for (let i = 1; i < drafts.length; i++) if (drafts[i].sentAt <= drafts[i - 1].sentAt) drafts[i].sentAt = drafts[i - 1].sentAt + 1;

  let dayFirstIndex = 0;
  for (let i = 0; i < drafts.length; i++) {
    const m = drafts[i];
    if (i === 0 || drafts[i - 1].day !== m.day) dayFirstIndex = i;
    m.text = messageText(rng);
    if (rng() < 0.05) {
      const n = rng() < 0.85 ? 1 : randInt(rng, 2, 4);
      for (let k = 0; k < n; k++) {
        const [w, h] = imageSize(rng);
        const id = `img_${conv.id}_${i + 1}_${k}`;
        media.set(id, { width: w, height: h, ext: "png", mime: "image/png" });
        m.attachments.push({ id, kind: "image", width: w, height: h });
      }
      if (rng() < 0.5) m.text = "";
    }
    if (i > dayFirstIndex && rng() < 0.04) m.replyToIndex = randInt(rng, dayFirstIndex, i - 1);
    if (rng() < 0.02 && m.text) m.editedAt = m.sentAt + randInt(rng, 10_000, 300_000);
    if (rng() < 0.08) {
      const reactors = conv.participants.filter((p) => p.id !== m.senderId);
      const n = randInt(rng, 1, Math.min(3, reactors.length));
      const chosen = [...reactors].sort(() => rng() - 0.5).slice(0, n);
      m.reactions = chosen.map((p) => ({ participantId: p.id, reaction: pick(rng, REACTIONS) }));
    }
    if (m.senderId === ME.id) {
      if (conv.kind === "direct") {
        m.status = "read";
        m.readAt = m.sentAt + randInt(rng, 5_000, 1_800_000);
      } else m.status = "delivered";
    }
  }
  for (const d of drafts) {
    const { day, replyToIndex, ...rest } = d;
    store.append(rest);
  }
  for (let i = 0; i < drafts.length; i++) {
    const ri = drafts[i].replyToIndex;
    if (ri === undefined) continue;
    const parent = store.messages[ri];
    store.messages[i].replyToId = parent.id;
    parent.replyCount++;
  }
}

// ---------------------------------------------------------------- conversations

const stores = new Map<string, Store>();
function boot() {
  const t0 = performance.now();
  const group = new Store({ id: "group", title: "cmux", kind: "group", participants: [ME, LAWRENCE, AUSTIN, LEO] });
  const direct = new Store({ id: "direct", title: "John Appleseed", kind: "direct", participants: [ME, JOHN] });
  generateHistory(group, GROUP_COUNT, 0.25, SEED);
  generateHistory(direct, DIRECT_COUNT, 0.45, SEED + 1);
  stores.set("group", group);
  stores.set("direct", direct);
  log(
    `history ready seed=${SEED} group=${group.headSeq} direct=${direct.headSeq} images=${media.size} in ${Math.round(performance.now() - t0)}ms`,
  );
}

// ---------------------------------------------------------------- connections

type WS = ServerWebSocket<{ conn?: Conn; conversation: string; base: string }>;
let connCounter = 0;

class Conn {
  id = ++connCounter;
  subscribed = false;
  clientId = "?";
  dropAt = 0;
  private queue: { at: number; frame: string }[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  private nextAt = 0;
  constructor(public ws: WS, public store: Store, public base: string) {
    this.scheduleDrop();
  }

  scheduleDrop() {
    const s = knobs.disconnectEverySeconds;
    this.dropAt = s > 0 ? Date.now() + s * 1000 * uniform(0.5, 1.5) : 0;
  }

  /** Ordered outbound queue: each frame leaves no earlier than the previous one. */
  private enqueue(frame: string, delayMs: number) {
    const at = Math.max(this.nextAt, Date.now() + delayMs);
    this.nextAt = at;
    this.queue.push({ at, frame });
    this.pump();
  }
  private pump() {
    if (this.timer || !this.queue.length) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      const now = Date.now();
      while (this.queue.length && this.queue[0].at <= now) {
        const { frame } = this.queue.shift()!;
        if (this.ws.readyState === 1) this.ws.send(frame);
      }
      this.pump();
    }, Math.max(0, this.queue[0].at - Date.now()));
  }
  close() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.queue = [];
    this.subscribed = false;
  }

  respond(id: unknown, result: unknown) {
    this.enqueue(JSON.stringify({ jsonrpc: "2.0", id, result }), 0);
  }
  error(id: unknown, code: number, message: string) {
    this.enqueue(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }), 0);
  }
  notify(method: string, params: unknown, delayed: boolean) {
    this.enqueue(JSON.stringify({ jsonrpc: "2.0", method, params }), delayed ? lat(15, 350) : 0);
  }
  pushEvent(ev: LoggedEvent, delayed = true) {
    const params = { eventSeq: ev.eventSeq, kind: ev.kind, message: wireMessage(ev.message, this.base) };
    this.notify("event", params, delayed);
    if (R() < knobs.duplicateRate) this.notify("event", params, delayed);
  }
}

function wireMessage(m: Message, base: string) {
  const out: Record<string, unknown> = {
    id: m.id,
    seq: m.seq,
    senderId: m.senderId,
    sentAt: m.sentAt,
    text: m.text,
    replyCount: m.replyCount,
    reactions: m.reactions,
    attachments: m.attachments.map((a) => ({ ...a, url: `${base}/media/${a.id}.${media.get(a.id)?.ext ?? "png"}` })),
  };
  if (m.clientMessageId) out.clientMessageId = m.clientMessageId;
  if (m.replyToId) out.replyToId = m.replyToId;
  if (m.editedAt) out.editedAt = m.editedAt;
  if (m.status) out.status = m.status;
  if (m.readAt) out.readAt = m.readAt;
  return out;
}

// ---------------------------------------------------------------- RPC

class RpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}
const invalid = (msg: string) => new RpcError(-32602, msg);

async function handleRpc(conn: Conn, rpcId: unknown, method: string, p: any): Promise<unknown> {
  const store = conn.store;
  if (method !== "hello" && !conn.subscribed) throw new RpcError(-32003, "hello required");
  switch (method) {
    case "hello": {
      await sleep(lat(40, 200));
      conn.clientId = String(p?.clientId ?? "?");
      const resume = p?.resumeAfterEventSeq;
      let lagged = false;
      let replay: LoggedEvent[] = [];
      if (resume !== undefined && resume !== null) {
        if (typeof resume !== "number" || !Number.isInteger(resume) || resume < 0) throw invalid("resumeAfterEventSeq");
        const gap = store.headEventSeq - resume;
        if (gap > REPLAY_LIMIT || resume > store.headEventSeq || resume + 1 < store.oldestEventSeq) lagged = true;
        else replay = store.events.filter((e) => e.eventSeq > resume);
      }
      conn.subscribed = true;
      const result = {
        conversation: store.conv,
        me: ME,
        headSeq: store.headSeq,
        headEventSeq: store.headEventSeq,
        serverTime: Date.now(),
        lagged,
      };
      if (rpcId !== undefined) conn.respond(rpcId, result);
      if (resume !== undefined && resume !== null && !lagged) {
        for (const ev of replay) conn.pushEvent(ev, false);
        conn.notify("replayDone", {}, false);
      }
      log(
        `hello conn=${conn.id} conv=${store.conv.id} client=${conn.clientId} resume=${resume ?? "-"} replay=${replay.length} lagged=${lagged}`,
      );
      return NO_RESPONSE;
    }
    case "history": {
      const limit = p?.limit ?? 50;
      const before = p?.beforeSeq ?? null;
      if (!Number.isInteger(limit) || limit < 1) throw invalid("limit");
      if (before !== null && !Number.isInteger(before)) throw invalid("beforeSeq");
      await sleep(lognormalHistoryDelay());
      if (R() < knobs.historyFailRate) throw new RpcError(-32001, "upstream timeout");
      const n = Math.min(limit, 200);
      const end = before === null ? store.headSeq : Math.min(Math.max(before - 1, 0), store.headSeq); // last seq included
      const start = Math.max(1, end - n + 1);
      const messages = end >= 1 ? store.messages.slice(start - 1, end).map((m) => wireMessage(m, conn.base)) : [];
      return { messages, hasMore: end >= 1 && start > 1 };
    }
    case "send":
      return { message: wireMessage(await handleSend(conn, p), conn.base) };
    case "react": {
      const m = store.byId.get(p?.messageId);
      if (!m) throw invalid("unknown messageId");
      const reaction = p?.reaction ?? null;
      if (reaction !== null && !REACTIONS.includes(reaction)) throw invalid("reaction");
      await sleep(lat(80, 400));
      m.reactions = m.reactions.filter((r) => r.participantId !== ME.id);
      if (reaction) m.reactions.push({ participantId: ME.id, reaction });
      store.emit("message.updated", m);
      return { message: wireMessage(m, conn.base) };
    }
    case "edit": {
      const m = store.byId.get(p?.messageId);
      if (!m) throw invalid("unknown messageId");
      if (m.senderId !== ME.id) throw invalid("can only edit my messages");
      if (typeof p?.text !== "string" || !p.text.length) throw invalid("text");
      await sleep(lat(120, 600));
      m.text = p.text;
      m.editedAt = Date.now();
      store.emit("message.updated", m);
      return { message: wireMessage(m, conn.base) };
    }
    case "typing":
      if (typeof p?.isTyping !== "boolean") throw invalid("isTyping");
      vlog(`typing conn=${conn.id} ${p.isTyping}`);
      return {};
    case "markRead":
      if (!Number.isInteger(p?.upToSeq)) throw invalid("upToSeq");
      store.lastReadSeq = Math.max(store.lastReadSeq, Math.min(p.upToSeq, store.headSeq));
      return {};
    default:
      throw new RpcError(-32601, `method not found: ${method}`);
  }
}

const NO_RESPONSE = Symbol("no-response");

async function handleSend(conn: Conn, p: any): Promise<Message> {
  const store = conn.store;
  const cmid = p?.clientMessageId;
  if (typeof cmid !== "string" || !cmid) throw invalid("clientMessageId");
  const text = p?.text ?? "";
  if (typeof text !== "string") throw invalid("text");
  const attachmentIds: string[] = p?.attachmentIds ?? [];
  if (!Array.isArray(attachmentIds)) throw invalid("attachmentIds");
  for (const a of attachmentIds) if (!media.has(a)) throw invalid(`unknown attachment ${a}`);
  if (!text && !attachmentIds.length) throw invalid("empty message");
  if (p?.replyToId && !store.byId.get(p.replyToId)) throw invalid("unknown replyToId");

  await sleep(lat(120, 900));
  const existing = store.byClientId.get(cmid);
  if (existing) {
    if (R() < knobs.failRate) throw new RpcError(-32002, "not delivered");
    return existing;
  }
  // Failure modes: half are lost before storage (retry creates it), half lose
  // only the ack (message exists; retry returns the original).
  const fail = R() < knobs.failRate;
  if (fail && R() < 0.5) throw new RpcError(-32002, "not delivered");
  const attachments: AttachmentRef[] = attachmentIds.map((id) => {
    const e = media.get(id)!;
    return { id, kind: "image", width: e.width, height: e.height };
  });
  const m = store.create(ME.id, text, { clientMessageId: cmid, replyToId: p?.replyToId || undefined, attachments });
  afterMySend(store, m);
  if (fail) throw new RpcError(-32002, "not delivered");
  return m;
}

function afterMySend(store: Store, m: Message) {
  setTimeout(() => {
    m.status = "delivered";
    store.emit("message.updated", m);
    if (store.conv.kind === "direct") {
      setTimeout(() => {
        m.status = "read";
        m.readAt = Date.now();
        store.emit("message.updated", m);
      }, lat(2000, 10_000));
    }
  }, lat(300, 1200));
  // Bots react to my message.
  if (R() < 0.75) void botReply(store, m);
  if (R() < 0.3) {
    void (async () => {
      await botSleep(uniform(1500, 6000));
      const bot = pick(R, store.bots());
      m.reactions = m.reactions.filter((r) => r.participantId !== bot.id);
      m.reactions.push({ participantId: bot.id, reaction: pick(R, REACTIONS) });
      store.emit("message.updated", m);
    })();
  }
}

// ---------------------------------------------------------------- bots

function typingMs(text: string) {
  return Math.min(9000, Math.max(1200, text.length * 45));
}

async function botSay(store: Store, bot: Participant, text: string, opts: Partial<Message> = {}, typingFor?: number) {
  store.broadcastTyping(bot.id, true);
  await botSleep(typingFor ?? typingMs(text));
  store.broadcastTyping(bot.id, false);
  const m = store.create(bot.id, text, opts);
  if (R() < 0.05) {
    void (async () => {
      await botSleep(uniform(4000, 20_000));
      m.text = editedText(R, m.text || "photo");
      m.editedAt = Date.now();
      store.emit("message.updated", m);
    })();
  }
  return m;
}

async function botReply(store: Store, mine: Message) {
  const total = uniform(3000, 12_000);
  const typing = Math.min(total * 0.7, typingMs("x".repeat(40)));
  await botSleep(total - typing);
  const bot = pick(R, store.bots());
  await botSay(store, bot, replyText(R), R() < 0.35 ? { replyToId: mine.id } : {}, typing);
}

function randomBotMessage(store: Store): { text: string; opts: Partial<Message> } {
  const opts: Partial<Message> = {};
  let text = messageText(R);
  if (R() < 0.04) {
    const [w, h] = imageSize(R);
    const id = `img_${store.conv.id}_live_${crypto.randomUUID().slice(0, 8)}`;
    media.set(id, { width: w, height: h, ext: "png", mime: "image/png" });
    opts.attachments = [{ id, kind: "image", width: w, height: h }];
    if (R() < 0.5) text = "";
  }
  if (R() < 0.05 && store.headSeq > 1) {
    const parent = store.messages[store.headSeq - 1 - Math.floor(R() * Math.min(30, store.headSeq))];
    opts.replyToId = parent.id;
  }
  return { text, opts };
}

async function botLoop(store: Store) {
  for (;;) {
    try {
      await botSleep(uniform(5000, 25_000));
      const bot = pick(R, store.bots());
      const roll = R();
      if (roll < 0.08) {
        const n = randInt(R, 3, 6);
        for (let i = 0; i < n; i++) {
          const { text, opts } = randomBotMessage(store);
          await botSay(store, bot, text, opts, uniform(500, 1800));
        }
      } else if (roll < 0.23) {
        // Starts typing, then gives up.
        store.broadcastTyping(bot.id, true);
        await botSleep(uniform(1500, 6000));
        store.broadcastTyping(bot.id, false);
      } else {
        const { text, opts } = randomBotMessage(store);
        await botSay(store, bot, text, opts);
      }
      if (R() < 0.1 && store.headSeq) {
        const target = store.messages[store.headSeq - 1 - Math.floor(R() * Math.min(10, store.headSeq))];
        const reactor = pick(R, store.bots().filter((b) => b.id !== target.senderId).concat(store.bots()));
        target.reactions = target.reactions.filter((r) => r.participantId !== reactor.id);
        target.reactions.push({ participantId: reactor.id, reaction: pick(R, REACTIONS) });
        store.emit("message.updated", target);
      }
    } catch (e) {
      log(`bot loop error conv=${store.conv.id} ${e}`);
    }
  }
}

async function burst(store: Store, count: number, intervalMs?: number) {
  for (let i = 0; i < count; i++) {
    const bot = pick(R, store.bots());
    const { text, opts } = randomBotMessage(store);
    store.create(bot.id, text, opts);
    if (intervalMs === undefined) await sleep(uniform(150, 600));
    else if (intervalMs > 0) await sleep(intervalMs);
  }
}

// ---------------------------------------------------------------- HTTP

const pngCache = new Map<string, Uint8Array>();
const PNG_CACHE_CAP = 300;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function applyKnobs(input: Record<string, unknown>): Knobs {
  const unitRange = ["failRate", "historyFailRate", "duplicateRate"];
  for (const [k, v] of Object.entries(input)) {
    if (!(k in knobs)) throw new Error(`unknown knob ${k}`);
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) throw new Error(`bad value for ${k}`);
    (knobs as Record<string, number>)[k] = unitRange.includes(k) ? Math.min(1, n) : n;
  }
  if ("disconnectEverySeconds" in input) for (const s of stores.values()) for (const c of s.conns) c.scheduleDrop();
  return knobs;
}

function dropAll(reason: string) {
  let n = 0;
  for (const s of stores.values())
    for (const c of [...s.conns]) {
      c.ws.terminate();
      n++;
    }
  log(`${reason}: dropped ${n} socket(s)`);
  return n;
}

async function handleHttp(req: Request, server: ReturnType<typeof Bun.serve>): Promise<Response | undefined> {
  const url = new URL(req.url);
  const base = `http://${req.headers.get("host") ?? `127.0.0.1:${PORT}`}`;
  const path = url.pathname;

  if (path === "/ws") {
    const conversation = url.searchParams.get("conversation") ?? "group";
    if (!stores.has(conversation)) return new Response(`unknown conversation ${conversation}`, { status: 404 });
    if (server.upgrade(req, { data: { conversation, base } })) return undefined;
    return new Response("upgrade failed", { status: 400 });
  }
  if (path === "/healthz") return new Response("ok");

  const mediaMatch = path.match(/^\/media\/([A-Za-z0-9_\-]+)\.([a-z]+)$/);
  if (mediaMatch && req.method === "GET") {
    const [, id] = mediaMatch;
    const entry = media.get(id);
    if (!entry) return new Response("not found", { status: 404 });
    await sleep(lat(200, 1500));
    let bytes = entry.bytes ?? pngCache.get(id);
    if (!bytes) {
      bytes = proceduralPNG(id, entry.width, entry.height);
      pngCache.set(id, bytes);
      if (pngCache.size > PNG_CACHE_CAP) pngCache.delete(pngCache.keys().next().value!);
    }
    vlog(`media ${id} ${bytes.length}B`);
    return new Response(bytes, { headers: { "content-type": entry.mime, "cache-control": "public, max-age=86400" } });
  }

  if (path === "/upload" && req.method === "POST") {
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (!bytes.length) return json({ error: "empty body" }, 400);
    const sniff = sniffImageSize(bytes);
    const ctype = req.headers.get("content-type") ?? "application/octet-stream";
    const width = sniff?.width || 1024;
    const height = sniff?.height || 768;
    const ext = sniff?.ext ?? (ctype.includes("png") ? "png" : ctype.includes("jpeg") || ctype.includes("jpg") ? "jpg" : "bin");
    const mime = sniff?.mime ?? ctype;
    const id = `up_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
    media.set(id, { width, height, ext, mime, bytes });
    log(`upload id=${id} ${bytes.length}B ${width}x${height} ${mime}`);
    return json({ attachment: { id, kind: "image", width, height, url: `${base}/media/${id}.${ext}` } });
  }

  if (path === "/admin/knobs") {
    if (req.method === "GET") return json(knobs);
    if (req.method === "POST") {
      try {
        const body = (await req.json()) as Record<string, unknown>;
        const k = applyKnobs(body);
        log(`admin knobs ${JSON.stringify(body)} -> ${JSON.stringify(k)}`);
        return json(k);
      } catch (e) {
        return json({ error: String((e as Error).message ?? e) }, 400);
      }
    }
  }
  if (path === "/admin/burst" && req.method === "POST") {
    const conv = url.searchParams.get("conversation") ?? "group";
    const store = stores.get(conv);
    if (!store) return json({ error: `unknown conversation ${conv}` }, 404);
    const count = Math.min(5000, Math.max(1, Number(url.searchParams.get("count") ?? 10) || 10));
    const iv = url.searchParams.get("intervalMs");
    const intervalMs = iv === null ? undefined : Math.max(0, Number(iv) || 0);
    log(`admin burst conv=${conv} count=${count} intervalMs=${intervalMs ?? "150-600"}`);
    if (intervalMs === 0) await burst(store, count, 0);
    else void burst(store, count, intervalMs);
    return json({ ok: true, conversation: conv, count, headSeq: store.headSeq, headEventSeq: store.headEventSeq });
  }
  if (path === "/admin/disconnect" && req.method === "POST") {
    return json({ ok: true, dropped: dropAll("admin disconnect") });
  }
  if (path === "/admin/state" && req.method === "GET") {
    const conversations: Record<string, unknown> = {};
    for (const [id, s] of stores)
      conversations[id] = {
        headSeq: s.headSeq,
        headEventSeq: s.headEventSeq,
        oldestEventSeq: s.oldestEventSeq,
        connections: s.conns.size,
        lastReadSeq: s.lastReadSeq,
      };
    return json({ knobs, conversations, uploads: [...media.values()].filter((m) => m.bytes).length });
  }
  return new Response("not found", { status: 404 });
}

// ---------------------------------------------------------------- main

boot();

const server = Bun.serve<{ conn?: Conn; conversation: string; base: string }>({
  port: PORT,
  hostname: HOST,
  idleTimeout: 60,
  fetch: (req, srv) => handleHttp(req, srv as any),
  websocket: {
    idleTimeout: 120,
    open(ws) {
      const store = stores.get(ws.data.conversation)!;
      const conn = new Conn(ws as WS, store, ws.data.base);
      ws.data.conn = conn;
      store.conns.add(conn);
      log(`connect conn=${conn.id} conv=${store.conv.id} remote=${ws.remoteAddress} (${store.conns.size} open)`);
    },
    message(ws, raw) {
      const conn = ws.data.conn!;
      let req: any;
      try {
        req = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
      } catch {
        conn.error(null, -32700, "parse error");
        return;
      }
      if (!req || typeof req.method !== "string") {
        conn.error(req?.id ?? null, -32600, "invalid request");
        return;
      }
      const id = req.id;
      vlog(`rpc conn=${conn.id} ${req.method} ${JSON.stringify(req.params ?? {})}`);
      // hello responds itself so replay frames follow the response in order.
      handleRpc(conn, id, req.method, req.params ?? {}).then(
        (result) => {
          if (result !== NO_RESPONSE && id !== undefined) conn.respond(id, result);
        },
        (e) => {
          if (id === undefined) return;
          if (e instanceof RpcError) conn.error(id, e.code, e.message);
          else {
            log(`internal error conn=${conn.id} ${req.method}: ${e}`);
            conn.error(id, -32603, "internal error");
          }
        },
      );
    },
    close(ws, code) {
      const conn = ws.data.conn;
      if (!conn) return;
      conn.close();
      conn.store.conns.delete(conn);
      log(`disconnect conn=${conn.id} conv=${conn.store.conv.id} code=${code} (${conn.store.conns.size} open)`);
    },
  },
});

setInterval(() => {
  const now = Date.now();
  for (const s of stores.values())
    for (const c of [...s.conns])
      if (c.dropAt && now >= c.dropAt) {
        log(`simulated drop conn=${c.id} conv=${s.conv.id}`);
        c.ws.terminate();
      }
}, 1000);

for (const s of stores.values()) void botLoop(s);
log(`conversation-sim listening on http://${HOST}:${server.port} (ws: /ws?conversation=group|direct)`);
