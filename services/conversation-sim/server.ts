// conversation-sim: long-running fake remote chat service. See PROTOCOL.md.
// Run: bun run services/conversation-sim/server.ts  (PORT, HOST, SEED, LOG=verbose)
import type { ServerWebSocket } from "bun";
import { mulberry32, proceduralPNG, sniffImageSize } from "./png";
import { editedText, imageSize, mentionText, messageText, pick, randInt, replyText, type Rng } from "./corpus";
import { AUDIO_EXPIRY_MS, audioWaveform, proceduralWAV, sniffWAVDurationMs, spokenDurationMs, spokenText } from "./audio";
import { LINK_MESSAGES, type LinkPreview, previewImages, previewURL, unfurl } from "./links";

// ---------------------------------------------------------------- types

type Reaction = "heart" | "thumbsup" | "thumbsdown" | "haha" | "exclamation" | "question";
const REACTIONS: Reaction[] = ["heart", "thumbsup", "thumbsdown", "haha", "exclamation", "question"];
/** Messages "send with effect": four bubble effects, then eight full-screen effects. */
type Effect =
  | "slam" | "loud" | "gentle" | "invisibleInk"
  | "echo" | "spotlight" | "balloons" | "confetti" | "love" | "lasers" | "fireworks" | "celebration";
const EFFECTS: Effect[] = [
  "slam", "loud", "gentle", "invisibleInk",
  "echo", "spotlight", "balloons", "confetti", "love", "lasers", "fireworks", "celebration",
];

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
  // Conversation list state (pin, Hide Alerts, Mark as Unread, delete).
  pinned: boolean;
  pinOrder?: number;
  muted: boolean;
  markedUnread: boolean;
  deleted: boolean;
  // Details: Send Read Receipts for this conversation.
  sendReadReceipts: boolean;
}
const MAX_PINNED = Number(process.env.MAX_PINNED ?? 9);
interface AttachmentRef {
  id: string;
  kind: "image" | "audio";
  width: number;
  height: number;
  // audio only
  durationMs?: number;
  waveform?: number[]; // peak levels 0-100, evenly spaced
  transcript?: string;
  expiresAt?: number; // epoch ms; absent = kept / never expires
  kept?: boolean;
}
interface Mention {
  participantId: string;
  location: number; // UTF-16 offset into text
  length: number;
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
  editCount?: number;
  unsentAt?: number;
  reactions: { participantId: string; reaction: Reaction }[];
  attachments: AttachmentRef[];
  status?: "sent" | "delivered" | "read";
  readAt?: number;
  mentions?: Mention[];
  textRuns?: TextRun[];
  effect?: Effect;
}
// Rich text (iMessage formatting and animated text effects). Offsets are UTF-16
// code units into `text`, so they index JS strings, NSString and NSRange alike.
type TextStyle = "bold" | "italic" | "underline" | "strikethrough";
const TEXT_STYLES: TextStyle[] = ["bold", "italic", "underline", "strikethrough"];
type TextEffect = "big" | "small" | "shake" | "nod" | "explode" | "ripple" | "bloom" | "jitter";
const TEXT_EFFECTS: TextEffect[] = ["big", "small", "shake", "nod", "explode", "ripple", "bloom", "jitter"];
interface TextRun {
  start: number;
  length: number;
  styles?: TextStyle[];
  effect?: TextEffect;
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
  bytes?: Uint8Array; // uploads only; procedural media is generated on demand
  audio?: { durationMs: number; waveform: number[]; transcript?: string };
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
// Messages from others left unread at boot (the catch-up backlog).
const GROUP_UNREAD = Number(process.env.GROUP_UNREAD ?? 60);
const DIRECT_UNREAD = Number(process.env.DIRECT_UNREAD ?? 3);
// Senders not in my contacts: their links arrive as "Tap to Load Preview".
const STRANGERS = new Set((process.env.STRANGERS ?? "austin").split(",").filter(Boolean));

const knobs = {
  latencyScale: 1,
  failRate: 0.04,
  historyFailRate: 0.07,
  duplicateRate: 0.02,
  disconnectEverySeconds: 240,
  botIntervalScale: 1,
  botLinkRate: 0.05,
  /** Share of bot text messages sent with a Messages effect. */
  effectRate: 0.03,
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

/** First name: what a mention inserts. */
const mentionName = (p: Participant) => p.name.split(/\s+/)[0];

/** Valid mentions for `text`: known participants, in range, sorted, non-overlapping. */
function validMentions(raw: unknown, text: string, conv: Conversation): Mention[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw invalid("mentions");
  const out: Mention[] = [];
  for (const m of [...raw].sort((a, b) => a?.location - b?.location)) {
    const { participantId, location, length } = m ?? {};
    if (!conv.participants.some((p) => p.id === participantId)) throw invalid(`unknown mention participant ${participantId}`);
    if (!Number.isInteger(location) || !Number.isInteger(length) || location < 0 || length < 1 || location + length > text.length)
      throw invalid("mention range");
    const last = out.at(-1);
    if (last && location < last.location + last.length) throw invalid("overlapping mentions");
    out.push({ participantId, location, length });
  }
  return out;
}

/** A bot message mentioning `target` (anyone but the bot). */
function mentionMessage(rng: Rng, target: Participant): { text: string; mentions: Mention[] } {
  const name = mentionName(target);
  const { text, location } = mentionText(rng, name);
  return { text, mentions: [{ participantId: target.id, location, length: name.length }] };
}

/** Who a bot mentions: me half the time, otherwise another bot. */
function mentionTarget(rng: Rng, conv: Conversation, bot: Participant): Participant | undefined {
  if (conv.kind !== "group") return undefined;
  const others = conv.participants.filter((p) => p.id !== bot.id && !p.isMe);
  return rng() < 0.5 || !others.length ? ME : pick(rng, others);
}

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
  /** Highest seq others were told I read (advances only while Send Read Receipts is on). */
  receiptSeq = 0;
  constructor(public conv: Conversation) {}

  /** Messages from others after the read marker. */
  unreadCount() {
    let n = 0;
    for (let seq = this.headSeq; seq > this.lastReadSeq; seq--) if (this.messages[seq - 1].senderId !== ME.id) n++;
    return n;
  }
  readState() {
    return { lastReadSeq: this.lastReadSeq, unreadCount: this.unreadCount(), headSeq: this.headSeq };
  }
  /** Moves the read marker (any device's markRead, my send, admin) and tells every device. */
  setLastRead(seq: number, force = false) {
    const next = Math.max(0, Math.min(seq, this.headSeq));
    if (!force && next <= this.lastReadSeq) return;
    if (next === this.lastReadSeq) return;
    this.lastReadSeq = next;
    const state = this.readState();
    for (const c of this.conns) if (c.subscribed) c.notify("readState", state, true);
  }
  /** Places the read marker so exactly `count` messages from others are unread. */
  leaveUnread(count: number) {
    let seq = this.headSeq;
    let n = 0;
    while (seq > 0 && n < count) {
      if (this.messages[seq - 1].senderId !== ME.id) n++;
      seq--;
    }
    return seq;
  }

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

  broadcastConversation() {
    for (const c of this.conns) if (c.subscribed) c.notify("conversation", { conversation: wireConversation(this.conv) }, true);
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
    // Messages: a new message from someone else brings a deleted conversation back.
    if (!isMe && this.conv.deleted) {
      this.conv.deleted = false;
      this.broadcastConversation();
    }
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
  // Separate stream: adding effects must not shift the rest of the seeded corpus.
  const effectRng = mulberry32(seed ^ 0x5eed);
  for (let i = 0; i < drafts.length; i++) {
    const m = drafts[i];
    if (i === 0 || drafts[i - 1].day !== m.day) dayFirstIndex = i;
    m.text = messageText(rng);
    const target = m.senderId === ME.id ? undefined : rng() < 0.04 ? mentionTarget(rng, conv, conv.participants.find((p) => p.id === m.senderId)!) : undefined;
    if (target) Object.assign(m, mentionMessage(rng, target));
    else if (conv.kind === "group" && m.senderId === ME.id && rng() < 0.03) {
      Object.assign(m, mentionMessage(rng, pick(rng, others)));
    }
    if (rng() < 0.05) {
      const n = rng() < 0.85 ? 1 : randInt(rng, 2, 4);
      for (let k = 0; k < n; k++) {
        const [w, h] = imageSize(rng);
        const id = `img_${conv.id}_${i + 1}_${k}`;
        media.set(id, { width: w, height: h, ext: "png", mime: "image/png" });
        m.attachments.push({ id, kind: "image", width: w, height: h });
      }
      if (rng() < 0.5) {
        m.text = "";
        delete m.mentions;
      }
    }
    if (i > dayFirstIndex && rng() < 0.04) m.replyToIndex = randInt(rng, dayFirstIndex, i - 1);
    if (rng() < 0.02 && m.text) m.editedAt = m.sentAt + randInt(rng, 10_000, 300_000);
    if (rng() < 0.08) {
      const reactors = conv.participants.filter((p) => p.id !== m.senderId);
      const n = randInt(rng, 1, Math.min(3, reactors.length));
      const chosen = [...reactors].sort(() => rng() - 0.5).slice(0, n);
      m.reactions = chosen.map((p) => ({ participantId: p.id, reaction: pick(rng, REACTIONS) }));
    }
    if (effectRng() < 0.015 && m.text && !m.attachments.length) m.effect = pick(effectRng, EFFECTS);
    if (m.senderId === ME.id) {
      if (conv.kind === "direct") {
        m.status = "read";
        m.readAt = m.sentAt + randInt(rng, 5_000, 1_800_000);
      } else m.status = "delivered";
    }
  }
  addHistoryAudio(conv, drafts, seed);
  // Own stream so adding formatting leaves the seeded history otherwise identical.
  const formatRng = mulberry32(seed ^ 0x7e57);
  for (const d of drafts) {
    const { day, replyToIndex, ...rest } = d;
    const textRuns = randomTextRuns(formatRng, rest.text);
    if (textRuns) (rest as Partial<Message>).textRuns = textRuns;
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

/** An audio attachment with procedural media (history and bots). */
function makeAudioAttachment(id: string, rng: Rng, transcript = spokenText(rng)): AttachmentRef {
  const durationMs = spokenDurationMs(transcript, rng);
  const waveform = audioWaveform(id, durationMs);
  media.set(id, { width: 0, height: 0, ext: "wav", mime: "audio/wav", audio: { durationMs, waveform, transcript } });
  return { id, kind: "audio", width: 0, height: 0, durationMs, waveform, transcript };
}

/**
 * Turns ~1.5% of history into audio messages, plus a guaranteed recent pair
 * (two consecutive incoming recordings, for auto-play) and one of mine near
 * the newest page. Uses its own rng so the rest of history is unchanged.
 */
function addHistoryAudio(conv: Conversation, drafts: (Omit<Message, "id" | "seq"> & { day: number })[], seed: number) {
  const rng = mulberry32(seed ^ 0xa0d10);
  const toAudio = (i: number) => {
    const m = drafts[i];
    m.text = "";
    m.editedAt = undefined;
    delete m.mentions; // they indexed the replaced text
    delete m.effect; // effects belong to text messages
    m.attachments = [makeAudioAttachment(`aud_${conv.id}_${i + 1}`, rng)];
  };
  for (let i = 0; i < drafts.length - 40; i++) if (rng() < 0.015 && !drafts[i].attachments.length) toAudio(i);
  const n = drafts.length;
  let pair = -1;
  for (let i = n - 14; i < n - 4 && pair < 0; i++) {
    if (drafts[i].senderId !== ME.id && drafts[i].senderId === drafts[i + 1].senderId) pair = i;
  }
  if (pair < 0) {
    // No natural pair: let one participant say two things in a row.
    pair = n - 9;
    const sender = drafts[pair].senderId !== ME.id ? drafts[pair].senderId : conv.participants.find((p) => !p.isMe)!.id;
    for (const d of [drafts[pair], drafts[pair + 1]]) {
      d.senderId = sender;
      delete d.status;
      delete d.readAt;
    }
  }
  toAudio(pair);
  toAudio(pair + 1);
  // Mine sits above the boot unread backlog, which is all from others.
  const backlog = conv.kind === "group" ? GROUP_UNREAD : DIRECT_UNREAD;
  for (let i = n - 1 - backlog; i >= n - 10 - backlog; i--) {
    if (drafts[i].senderId === ME.id && !drafts[i].attachments.length) {
      toAudio(i);
      break;
    }
  }
}

// ---------------------------------------------------------------- conversations

const stores = new Map<string, Store>();
function boot() {
  const t0 = performance.now();
  const listState = { pinned: false, muted: false, markedUnread: false, deleted: false, sendReadReceipts: true };
  const group = new Store({ id: "group", title: "cmux", kind: "group", participants: [ME, LAWRENCE, AUSTIN, LEO], ...listState });
  const direct = new Store({ id: "direct", title: "John Appleseed", kind: "direct", participants: [ME, JOHN], ...listState });
  generateHistory(group, GROUP_COUNT, 0.25, SEED);
  generateHistory(direct, DIRECT_COUNT, 0.45, SEED + 1);
  // A real backlog never contains my own messages (sending reads the
  // conversation), so the boot backlog is the last N messages, all from others.
  for (const store of [group, direct]) {
    const n = store === group ? GROUP_UNREAD : DIRECT_UNREAD;
    const bots = store.bots();
    for (let seq = Math.max(1, store.headSeq - n + 1); seq <= store.headSeq; seq++) {
      const m = store.messages[seq - 1];
      if (m.senderId !== ME.id) continue;
      m.senderId = bots[seq % bots.length].id;
      delete m.status;
      delete m.readAt;
    }
    store.lastReadSeq = store.leaveUnread(n);
  }
  stores.set("group", group);
  stores.set("direct", direct);
  log(
    `history ready seed=${SEED} group=${group.headSeq} direct=${direct.headSeq} media=${media.size} in ${Math.round(performance.now() - t0)}ms`,
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

function wireConversation(c: Conversation) {
  const out: Record<string, unknown> = {
    id: c.id,
    title: c.title,
    kind: c.kind,
    participants: c.participants,
    pinned: c.pinned,
    muted: c.muted,
    markedUnread: c.markedUnread,
    deleted: c.deleted,
    sendReadReceipts: c.sendReadReceipts,
  };
  if (c.pinned && c.pinOrder !== undefined) out.pinOrder = c.pinOrder;
  return out;
}

/** Applies a list action with Messages' rules; throws on an invalid one. */
function updateConversation(store: Store, p: any): Conversation {
  const c = store.conv;
  for (const key of ["pinned", "muted", "markedUnread", "deleted", "sendReadReceipts"])
    if (p?.[key] !== undefined && typeof p[key] !== "boolean") throw invalid(key);
  if (p?.pinOrder !== undefined && (!Number.isInteger(p.pinOrder) || p.pinOrder < 0)) throw invalid("pinOrder");
  const deleting = p?.deleted === true;
  const willBeDeleted = p?.deleted ?? c.deleted;
  if (p?.pinned === true && !c.pinned && !deleting) {
    if (willBeDeleted) throw invalid("cannot pin a deleted conversation");
    let pinnedElsewhere = 0;
    for (const s of stores.values()) if (s !== store && s.conv.pinned && !s.conv.deleted) pinnedElsewhere++;
    if (pinnedElsewhere >= MAX_PINNED) throw new RpcError(-32004, "pin limit");
    let last = -1;
    for (const s of stores.values()) if (s !== store && s.conv.pinned) last = Math.max(last, s.conv.pinOrder ?? -1);
    c.pinned = true;
    c.pinOrder = last + 1;
  }
  if (p?.pinned === false) {
    c.pinned = false;
    delete c.pinOrder;
  }
  if (p?.pinOrder !== undefined && c.pinned) c.pinOrder = p.pinOrder;
  if (p?.muted !== undefined) c.muted = p.muted;
  if (p?.markedUnread !== undefined) c.markedUnread = p.markedUnread;
  if (p?.sendReadReceipts !== undefined) c.sendReadReceipts = p.sendReadReceipts;
  if (p?.deleted !== undefined) {
    c.deleted = p.deleted;
    if (c.deleted) {
      c.pinned = false;
      delete c.pinOrder;
      c.markedUnread = false;
    }
  }
  return c;
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
  if (m.editCount) out.editCount = m.editCount;
  if (m.unsentAt) out.unsentAt = m.unsentAt;
  if (m.status) out.status = m.status;
  if (m.readAt) out.readAt = m.readAt;
  if (m.mentions?.length) out.mentions = m.mentions;
  if (m.textRuns?.length) out.textRuns = m.textRuns;
  const preview = linkPreviewFor(m);
  if (preview) out.linkPreview = wireLinkPreview(preview, base);
  if (m.effect) out.effect = m.effect;
  return out;
}

// ---------------------------------------------------------------- link previews

const unfurlCache = new Map<string, LinkPreview>();
function unfurlCached(url: string): LinkPreview {
  let p = unfurlCache.get(url);
  if (!p) {
    p = unfurl(url);
    for (const img of previewImages(p)) {
      if (!media.has(img.id)) media.set(img.id, { width: img.width, height: img.height, ext: "png", mime: "image/png" });
    }
    unfurlCache.set(url, p);
    if (unfurlCache.size > 2000) unfurlCache.delete(unfurlCache.keys().next().value!);
  }
  return p;
}

function linkPreviewFor(m: Message): LinkPreview | undefined {
  const url = previewURL(m.text);
  if (!url) return undefined;
  if (STRANGERS.has(m.senderId)) return { url, state: "tapToLoad" };
  return unfurlCached(url);
}

function wireLinkPreview(p: LinkPreview, base: string) {
  const image = (i: LinkPreview["image"]) => i && { url: `${base}/media/${i.id}.png`, width: i.width, height: i.height };
  const out: Record<string, unknown> = { url: p.url, state: p.state ?? "loaded" };
  if (p.title) out.title = p.title;
  if (p.siteName) out.siteName = p.siteName;
  if (p.image) out.image = image(p.image);
  if (p.icon) out.icon = image(p.icon);
  return out;
}

// ---------------------------------------------------------------- rich text

/** Validates client runs: in bounds, non-overlapping, known styles/effects. Empty runs are dropped. */
function parseTextRuns(raw: unknown, text: string): TextRun[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) throw invalid("textRuns");
  const runs: TextRun[] = [];
  for (const r of raw) {
    const start = r?.start;
    const length = r?.length;
    if (!Number.isInteger(start) || !Number.isInteger(length) || start < 0 || length < 0 || start + length > text.length) {
      throw invalid("textRuns range");
    }
    const styles = r?.styles ?? [];
    if (!Array.isArray(styles) || styles.some((x: unknown) => !TEXT_STYLES.includes(x as TextStyle))) throw invalid("textRuns styles");
    const effect = r?.effect ?? undefined;
    if (effect !== undefined && !TEXT_EFFECTS.includes(effect)) throw invalid("textRuns effect");
    if (length === 0 || (!styles.length && !effect)) continue;
    const run: TextRun = { start, length };
    if (styles.length) run.styles = TEXT_STYLES.filter((x) => styles.includes(x));
    if (effect) run.effect = effect;
    runs.push(run);
  }
  runs.sort((a, b) => a.start - b.start);
  for (let i = 1; i < runs.length; i++) {
    if (runs[i].start < runs[i - 1].start + runs[i - 1].length) throw invalid("textRuns overlap");
  }
  return runs.length ? runs : undefined;
}

/** Bots and history occasionally format a word or animate a whole message. */
function randomTextRuns(rng: Rng, text: string): TextRun[] | undefined {
  if (!text || rng() >= 0.06) return undefined;
  if (rng() < 0.5) return [{ start: 0, length: text.length, effect: pick(rng, TEXT_EFFECTS) }];
  const words = [...text.matchAll(/[A-Za-z']{3,}/g)];
  if (!words.length) return undefined;
  const w = pick(rng, words);
  const styles: TextStyle[] = [pick(rng, TEXT_STYLES)];
  if (rng() < 0.25) styles.push(pick(rng, TEXT_STYLES));
  return [{ start: w.index!, length: w[0].length, styles: TEXT_STYLES.filter((x) => styles.includes(x)) }];
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
        conversation: wireConversation(store.conv),
        me: ME,
        headSeq: store.headSeq,
        headEventSeq: store.headEventSeq,
        serverTime: Date.now(),
        lagged,
        ...store.readState(),
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
      if ((m.editCount ?? 0) >= 5) throw new RpcError(-32004, "edit limit reached");
      const textRuns = parseTextRuns(p?.textRuns, p.text);
      await sleep(lat(120, 600));
      keepUnchangedMentions(m, p.text);
      m.text = p.text;
      // An edit replaces the formatting with the edit's own (none when omitted).
      m.textRuns = textRuns;
      m.editedAt = Date.now();
      m.editCount = (m.editCount ?? 0) + 1;
      store.emit("message.updated", m);
      return { message: wireMessage(m, conn.base) };
    }
    case "unsend": {
      const m = store.byId.get(p?.messageId);
      if (!m) throw invalid("unknown messageId");
      if (m.senderId !== ME.id) throw invalid("can only unsend my messages");
      if (Date.now() - m.sentAt > 2 * 60_000) throw new RpcError(-32003, "undo send window closed");
      await sleep(lat(120, 600));
      m.unsentAt = Date.now();
      m.text = "";
      m.attachments = [];
      m.reactions = [];
      store.emit("message.updated", m);
      return { message: wireMessage(m, conn.base) };
    }
    case "keepAudio": {
      const m = store.byId.get(p?.messageId);
      if (!m) throw invalid("unknown messageId");
      const audio = m.attachments.find((a) => a.kind === "audio");
      if (!audio) throw invalid("not an audio message");
      await sleep(lat(80, 300));
      delete audio.expiresAt;
      audio.kept = true;
      store.emit("message.updated", m);
      return { message: wireMessage(m, conn.base) };
    }
    case "audioPlayed": {
      const m = store.byId.get(p?.messageId);
      if (!m) throw invalid("unknown messageId");
      const audio = m.attachments.find((a) => a.kind === "audio");
      if (!audio) throw invalid("not an audio message");
      // Listening starts the 2-minute expiry on someone else's recording.
      if (m.senderId !== ME.id && !audio.kept && !audio.expiresAt) {
        audio.expiresAt = Date.now() + AUDIO_EXPIRY_MS;
        store.emit("message.updated", m);
      }
      return {};
    }
    case "typing":
      if (typeof p?.isTyping !== "boolean") throw invalid("isTyping");
      vlog(`typing conn=${conn.id} ${p.isTyping}`);
      return {};
    case "updateConversation": {
      await sleep(lat(60, 300));
      const conv = updateConversation(store, p);
      log(`updateConversation conv=${conv.id} ${JSON.stringify(p ?? {})}`);
      store.broadcastConversation();
      return { conversation: wireConversation(conv) };
    }
    case "unfurl": {
      if (typeof p?.url !== "string" || !/^https?:\/\//i.test(p.url)) throw invalid("url");
      await sleep(lat(300, 1200));
      return { linkPreview: wireLinkPreview(unfurlCached(p.url), conn.base) };
    }
    case "markRead":
      if (!Number.isInteger(p?.upToSeq)) throw invalid("upToSeq");
      // The read receipt: on direct, the other side would now see "Read".
      store.setLastRead(p.upToSeq);
      // With Send Read Receipts off, others never learn this read.
      if (store.conv.sendReadReceipts) store.receiptSeq = Math.max(store.receiptSeq, store.lastReadSeq);
      vlog(`markRead conn=${conn.id} upTo=${p.upToSeq} lastRead=${store.lastReadSeq}`);
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
  const mentions = validMentions(p?.mentions, text, store.conv);
  const textRuns = parseTextRuns(p?.textRuns, text);
  const effect = p?.effect ?? undefined;
  if (effect !== undefined && effect !== null && !EFFECTS.includes(effect)) throw invalid("effect");

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
    if (e.audio) return { id, kind: "audio", width: 0, height: 0, ...e.audio, expiresAt: Date.now() + AUDIO_EXPIRY_MS };
    return { id, kind: "image", width: e.width, height: e.height };
  });
  const m = store.create(ME.id, text, {
    clientMessageId: cmid,
    replyToId: p?.replyToId || undefined,
    attachments,
    textRuns,
    ...(mentions.length ? { mentions } : {}),
    ...(effect ? { effect } : {}),
  });
  // Replying reads the conversation (Messages clears unread when you send).
  store.setLastRead(m.seq);
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

/** A mention survives an edit only when its text is unchanged at the same range. */
function keepUnchangedMentions(m: Message, next: string) {
  if (!m.mentions) return;
  const kept = m.mentions.filter((x) => x.location + x.length <= next.length && next.slice(x.location, x.location + x.length) === m.text.slice(x.location, x.location + x.length));
  if (kept.length) m.mentions = kept;
  else delete m.mentions;
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
  if (R() < 0.05 && !m.attachments.some((a) => a.kind === "audio")) {
    void (async () => {
      await botSleep(uniform(4000, 20_000));
      const next = editedText(R, m.text || "photo");
      keepUnchangedMentions(m, next);
      m.text = next;
      m.textRuns = undefined;
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

function randomBotMessage(store: Store, bot: Participant): { text: string; opts: Partial<Message> } {
  const opts: Partial<Message> = {};
  let text = messageText(R);
  // Bots occasionally mention someone (half the time me).
  const target = R() < 0.12 ? mentionTarget(R, store.conv, bot) : undefined;
  if (target) {
    const mention = mentionMessage(R, target);
    return { text: mention.text, opts: { mentions: mention.mentions } };
  }
  if (R() < 0.03) {
    opts.attachments = [makeAudioAttachment(`aud_${store.conv.id}_live_${crypto.randomUUID().slice(0, 8)}`, R)];
    return { text: "", opts };
  }
  if (R() < knobs.botLinkRate) return { text: pick(R, LINK_MESSAGES), opts };
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
  opts.textRuns = randomTextRuns(R, text);
  if (text && R() < knobs.effectRate) opts.effect = pick(R, EFFECTS);
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
          const { text, opts } = randomBotMessage(store, bot);
          await botSay(store, bot, text, opts, uniform(500, 1800));
        }
      } else if (roll < 0.23) {
        // Starts typing, then gives up.
        store.broadcastTyping(bot.id, true);
        await botSleep(uniform(1500, 6000));
        store.broadcastTyping(bot.id, false);
      } else {
        const { text, opts } = randomBotMessage(store, bot);
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
    const { text, opts } = randomBotMessage(store, bot);
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
  const unitRange = ["failRate", "historyFailRate", "duplicateRate", "effectRate"];
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
      bytes = entry.audio ? proceduralWAV(id, entry.audio.durationMs) : proceduralPNG(id, entry.width, entry.height);
      pngCache.set(id, bytes);
      if (pngCache.size > PNG_CACHE_CAP) pngCache.delete(pngCache.keys().next().value!);
    }
    vlog(`media ${id} ${bytes.length}B`);
    return new Response(bytes, { headers: { "content-type": entry.mime, "cache-control": "public, max-age=86400" } });
  }

  if (path === "/upload" && req.method === "POST") {
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (!bytes.length) return json({ error: "empty body" }, 400);
    const uploadType = req.headers.get("content-type") ?? "application/octet-stream";
    if (url.searchParams.get("kind") === "audio" || uploadType.startsWith("audio/")) {
      const durationMs = Number(url.searchParams.get("durationMs")) || sniffWAVDurationMs(bytes) || 0;
      if (!(durationMs > 0)) return json({ error: "durationMs required" }, 400);
      const waveform = (url.searchParams.get("waveform") ?? "")
        .split(",")
        .filter(Boolean)
        .map((v) => Math.max(0, Math.min(100, Math.round(Number(v) || 0))));
      const header = req.headers.get("x-transcript");
      const transcript = header ? decodeURIComponent(header) : undefined;
      const ext = uploadType.includes("wav") ? "wav" : uploadType.includes("mp4") || uploadType.includes("m4a") ? "m4a" : "bin";
      const id = `up_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
      const audio = { durationMs, waveform: waveform.length ? waveform : audioWaveform(id, durationMs), transcript };
      media.set(id, { width: 0, height: 0, ext, mime: uploadType, bytes, audio });
      log(`upload id=${id} ${bytes.length}B audio ${durationMs}ms ${uploadType}`);
      return json({ attachment: { id, kind: "audio", width: 0, height: 0, ...audio, url: `${base}/media/${id}.${ext}` } });
    }
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
  if (path === "/admin/mention" && req.method === "POST") {
    // A bot sends a message mentioning `target` (me by default) right away.
    const conv = url.searchParams.get("conversation") ?? "group";
    const store = stores.get(conv);
    if (!store) return json({ error: `unknown conversation ${conv}` }, 404);
    const targetId = url.searchParams.get("target") ?? ME.id;
    const target = store.conv.participants.find((p) => p.id === targetId);
    if (!target) return json({ error: `unknown participant ${targetId}` }, 404);
    const senders = store.bots().filter((b) => b.id !== target.id);
    const bot = store.conv.participants.find((p) => p.id === url.searchParams.get("from")) ?? pick(R, senders);
    const { text, mentions } = mentionMessage(R, target);
    const m = store.create(bot.id, text, { mentions });
    log(`admin mention conv=${conv} from=${bot.id} target=${target.id} seq=${m.seq}`);
    return json({ ok: true, message: wireMessage(m, base) });
  }
  if (path === "/admin/unread" && req.method === "POST") {
    const conv = url.searchParams.get("conversation") ?? "group";
    const store = stores.get(conv);
    if (!store) return json({ error: `unknown conversation ${conv}` }, 404);
    const count = Math.min(5000, Math.max(0, Number(url.searchParams.get("count") ?? 60) || 0));
    store.setLastRead(store.leaveUnread(count), true);
    log(`admin unread conv=${conv} count=${count} lastReadSeq=${store.lastReadSeq}`);
    return json({ ok: true, conversation: conv, ...store.readState() });
  }
  if (path === "/admin/audio" && req.method === "POST") {
    // One participant sends `count` audio messages back to back (auto-play testing).
    const conv = url.searchParams.get("conversation") ?? "group";
    const store = stores.get(conv);
    if (!store) return json({ error: `unknown conversation ${conv}` }, 404);
    const count = Math.min(10, Math.max(1, Number(url.searchParams.get("count") ?? 1) || 1));
    const bot = store.bots().find((b) => b.id === url.searchParams.get("sender")) ?? pick(R, store.bots());
    const created = [];
    for (let i = 0; i < count; i++) {
      const attachment = makeAudioAttachment(`aud_${conv}_admin_${crypto.randomUUID().slice(0, 8)}`, R);
      created.push(store.create(bot.id, "", { attachments: [attachment] }).id);
    }
    log(`admin audio conv=${conv} sender=${bot.id} count=${count}`);
    return json({ ok: true, conversation: conv, sender: bot.id, messageIds: created });
  }
  if (path === "/admin/say" && req.method === "POST") {
    // One message from a participant, now. Params come from a JSON body
    // {conversation, senderId, text, effect} (deterministic fixtures: posts at
    // once, I may be the sender) or the query (conversation, sender, text,
    // effect: a bot types briefly first, for receiver-side effect testing).
    // Text defaults to a random line; the sender to a random bot.
    const isJSON = req.headers.get("content-type")?.includes("json") ?? false;
    const body = isJSON ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};
    const param = (key: string, query = key) => {
      const value = isJSON ? body[key] : url.searchParams.get(query);
      return typeof value === "string" && value ? value : undefined;
    };
    const conv = param("conversation") ?? "group";
    const store = stores.get(conv);
    if (!store) return json({ error: `unknown conversation ${conv}` }, 404);
    const senderId = param("senderId", "sender");
    const sender = senderId ? store.conv.participants.find((p) => p.id === senderId) : pick(R, store.bots());
    if (!sender) return json({ error: `unknown sender ${senderId}` }, 400);
    const effect = param("effect");
    if (effect !== undefined && !EFFECTS.includes(effect as Effect)) return json({ error: `unknown effect ${effect}` }, 400);
    const text = param("text") ?? messageText(R);
    if (!isJSON && !sender.isMe) {
      // Real-time typing (not botSleep): bots may be paused via botIntervalScale.
      store.broadcastTyping(sender.id, true);
      await sleep(lat(400, 900));
      store.broadcastTyping(sender.id, false);
    }
    const m = store.create(sender.id, text, effect ? { effect: effect as Effect } : {});
    if (sender.isMe) afterMySend(store, m);
    log(`admin say conv=${conv} sender=${sender.id} effect=${effect ?? "-"}`);
    return json({ ok: true, message: wireMessage(m, base) });
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
        unreadCount: s.unreadCount(),
        listState: { pinned: s.conv.pinned, pinOrder: s.conv.pinOrder, muted: s.conv.muted, markedUnread: s.conv.markedUnread, deleted: s.conv.deleted, sendReadReceipts: s.conv.sendReadReceipts },
        receiptSeq: s.receiptSeq,
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
