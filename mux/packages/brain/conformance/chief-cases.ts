/**
 * The Chief corpus cases, built from intent. Each step names the effect kinds
 * it must produce (log effects aside) and checks what matters about them; the
 * TypeScript core must agree, and the generator records the full effects and
 * states so the Rust core (cmux-chief) compares JSON values.
 */
import type { AcpmuxEvent, SessionSummary } from "../src/core/acp.ts";
import { AGENT_MUX, type Message, type Participant, type Summary, USER_LOCAL } from "../src/core/conversation.ts";
import { Core, type Effect, type Input } from "../src/core/core.ts";
import { CORPUS_FORMAT, type Corpus, type CorpusCase, type CorpusStep, type MemoryCase, type MemoryFunction, memoryResult, plain } from "../src/core/corpus.ts";
import { PARENT_TAG } from "../src/core/rules.ts";
import { type HostStateData, loadState } from "../src/core/state.ts";

/** 2026-10-03T00:00:00.000Z. */
const T0 = 1_790_985_600_000;
const ISO = "2026-10-03T00:00:00.000Z";

const ME: Participant = { id: USER_LOCAL, kind: "human", display_name: "Me" };
const ANA: Participant = { id: "user_ana", kind: "human", display_name: "Ana" };
const MUX: Participant = { id: AGENT_MUX, kind: "agent", display_name: "mux", agent_class: "mux", acp_session: "mux" };

function summary(id: string, participants: Participant[] = [ME, MUX], cursor?: number): Summary {
  return {
    id,
    owner: "local",
    title: id,
    participants,
    last_seq: 0,
    rev: 1,
    created_at: ISO,
    updated_at: ISO,
    read_cursors: cursor === undefined ? {} : { [AGENT_MUX]: cursor },
  };
}

const msgId = (conversation: string, seq: number) => `m_${conversation}_${seq}`;

function msg(conversation: string, seq: number, author: string, text: string, extra: Partial<Message> = {}): Message {
  return {
    id: msgId(conversation, seq),
    conversation,
    seq,
    client_msg_id: `c_${conversation}_${seq}`,
    author,
    parts: [{ type: "text", text }],
    created_at: ISO,
    reactions: [],
    ...extra,
  };
}

function session(sessionId: string, name: string, status: SessionSummary["status"], extra: Partial<SessionSummary> = {}): SessionSummary {
  return {
    sessionId,
    name,
    harness: "claude",
    cwd: "/work",
    status,
    pendingPermissions: 0,
    stateSeq: 1,
    preview: null,
    tags: { [PARENT_TAG]: "mux" },
    ...extra,
  };
}

const MUX_SESSION = "s_mux";

function ev(seq: number, kind: string, msg: Record<string, unknown> = {}, dir = "mux", sessionId = MUX_SESSION): AcpmuxEvent {
  return { sessionId, seq, dir, kind, msg };
}

const chunk = (seq: number, text: string, sessionId = MUX_SESSION): AcpmuxEvent =>
  ev(seq, "agent_message_chunk", { params: { update: { content: { type: "text", text } } } }, "agent", sessionId);

const mux = (event: AcpmuxEvent): Input => ({ kind: "acpmux_event", event });
const live = (message: Message): Input => ({
  kind: "conversation_changed",
  conversation: message.conversation,
  change: { kind: "message", message },
});

type Kind = Effect["kind"];
type Of<K extends Kind> = Extract<Effect, { kind: K }>;

/** One case under construction. */
class CaseBuilder {
  readonly steps: CorpusStep[] = [];
  private readonly core: Core;
  private readonly start: HostStateData;
  now = T0;

  constructor(
    readonly name: string,
    state: Partial<HostStateData> = {},
  ) {
    this.start = plain(loadState(state));
    this.core = new Core(this.start);
  }

  fail(what: string): never {
    throw new Error(`${this.name}: step ${this.steps.length}: ${what}`);
  }

  check(condition: boolean, what: string): void {
    if (!condition) this.fail(what);
  }

  /** Feeds a setup input with no stated intent (it is recorded all the same). */
  feed(input: Input, afterMs = 1): Effect[] {
    this.now += afterMs;
    const effects = plain(this.core.step(plain(input), this.now));
    this.steps.push({ now: this.now, input: plain(input), effects });
    return effects;
  }

  /** Feeds an input that must produce exactly `kinds` (log effects aside); `check` states the rest. */
  step(input: Input, kinds: Kind[], check?: (effects: Effect[]) => void, afterMs = 1): Effect[] {
    const index = this.steps.length;
    const effects = this.feed(input, afterMs);
    const got = effects.filter((e) => e.kind !== "log").map((e) => e.kind);
    if (got.join(",") !== kinds.join(","))
      throw new Error(`${this.name}: step ${index}: want [${kinds.join(", ")}] got [${got.join(", ")}]`);
    check?.(effects);
    return effects;
  }

  /**
   * Feeds an input given as wire text (recorded as `input_text`): each core
   * parses it with its own JSON reader. For number text a JSON value cannot
   * carry, like `1.0`.
   */
  stepText(text: string, kinds: Kind[], check?: (effects: Effect[]) => void, afterMs = 1): Effect[] {
    const index = this.steps.length;
    this.now += afterMs;
    const effects = plain(this.core.step(JSON.parse(text) as Input, this.now));
    this.steps.push({ now: this.now, input_text: text, effects });
    const got = effects.filter((e) => e.kind !== "log").map((e) => e.kind);
    if (got.join(",") !== kinds.join(","))
      throw new Error(`${this.name}: step ${index}: want [${kinds.join(", ")}] got [${got.join(", ")}]`);
    check?.(effects);
    return effects;
  }

  /** The `n`th effect of `kind`. */
  get<K extends Kind>(effects: Effect[], kind: K, n = 0): Of<K> {
    const found = effects.filter((e): e is Of<K> => e.kind === kind)[n];
    if (!found) this.fail(`no ${kind} #${n}`);
    return found;
  }

  persisted(effects: Effect[]): HostStateData {
    return this.get(effects, "persist").state;
  }

  end(check?: (state: HostStateData) => void): CorpusCase {
    const state = plain(this.core.state);
    check?.(state);
    return { name: this.name, state: this.start, steps: this.steps, state_after: state };
  }
}

/** Both ports up and a quiet catch-up of `conversations` (the first is the default conversation). */
function boot(c: CaseBuilder, conversations: Summary[] = [summary("conv_a")], sessions: SessionSummary[] = []): void {
  c.feed({ kind: "daemon_connected", conversation: conversations[0] });
  c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions, events: [] });
  let effects = c.feed({ kind: "conversations_listed", conversations });
  for (const conversation of conversations) {
    if (!conversation.participants.some((p) => p.id === AGENT_MUX)) continue;
    c.check(
      effects.some((e) => e.kind === "fetch_snapshot" && e.conversation === conversation.id),
      `boot: no snapshot of ${conversation.id}`,
    );
    effects = c.feed({ kind: "snapshot", conversation, messages: [] });
  }
  c.check(effects.some((e) => e.kind === "ready"), "boot: not ready");
}

const opKey = (c: CaseBuilder, effects: Effect[], n = 0) => c.get(effects, "conversation_op", n).idempotency_key;

// MARK: cases

function wakeCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];

  {
    const c = new CaseBuilder("wake 1:1: a human message wakes the Chief; its turn is the reply, keyed by the turn, with typing");
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["persist"], (e) =>
      c.check(c.persisted(e).defaultConversation === "conv_a", "default conversation saved"),
    );
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] }, ["persist", "list_conversations"], (e) =>
      c.check(c.persisted(e).muxSessionId === MUX_SESSION, "mux session saved"),
    );
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a")] }, ["fetch_snapshot"], (e) =>
      c.check(c.get(e, "fetch_snapshot").tail === 500, "catch-up page"),
    );
    c.step({ kind: "snapshot", conversation: summary("conv_a"), messages: [] }, ["ready"]);
    const m1 = msg("conv_a", 1, USER_LOCAL, "hello");
    c.step(live(m1), ["persist", "prompt"], (e) => {
      const prompt = c.get(e, "prompt");
      c.check(prompt.prompt_id === m1.id, "promptId is the message id");
      c.check(prompt.text === "[conversation conv_a from Me] hello", "inbox prompt text");
    });
    c.step(mux(ev(1, "user_message", { promptId: m1.id })), ["conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "cursor:agent_mux:1" && op.op.kind === "read_cursor.set", "read cursor moves after acceptance");
    });
    c.step(mux(ev(2, "turn_started")), ["typing"], (e) => c.check(c.get(e, "typing").on, "typing on"));
    c.step(mux(chunk(3, "Hi ")), []);
    c.step(mux(chunk(4, "there ")), []);
    c.step(mux(ev(5, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === `turn:${MUX_SESSION}:2`, "reply key is turn:<session>:<turn_started seq>");
      c.check(op.op.kind === "message.send" && op.op.client_msg_id === op.idempotency_key, "client_msg_id is the key");
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "Hi there", "trimmed text");
      c.check(!c.get(e, "typing").on, "typing off");
      c.check(c.persisted(e).answered.includes(m1.id) && c.persisted(e).acpmuxSeq === 5, "answered and settled");
    });
    c.step({ kind: "op_result", idempotency_key: "cursor:agent_mux:1" }, []);
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:2` }, ["persist"], (e) =>
      c.check(c.persisted(e).outbox.length === 0, "outbox drained"),
    );
    cases.push(c.end((s) => c.check(Object.keys(s.prompts).length === 0, "no outstanding prompt")));
  }

  {
    const conv = summary("conv_g", [ME, ANA, MUX]);
    const c = new CaseBuilder("wake group: a plain message does not wake (the cursor still moves); a mention does; the Chief's own message does not; a reply to the Chief does");
    boot(c, [conv]);
    c.step(live(msg("conv_g", 1, "user_ana", "just chatting")), ["conversation_op"], (e) =>
      c.check(opKey(c, e) === "cursor:agent_mux:1", "cursor past the plain message"),
    );
    const mention = msg("conv_g", 2, "user_ana", "hey @mux status?", {
      parts: [{ type: "text", text: "hey @mux status?", runs: [{ start: 4, length: 4, mention: AGENT_MUX }] }],
    });
    c.step(live(mention), ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").text === "[conversation conv_g from Ana] hey @mux status?", "author display name"),
    );
    c.step(mux(ev(1, "user_message", { promptId: mention.id })), ["conversation_op"]);
    c.step(mux(ev(2, "turn_started")), ["typing"], (e) => c.check(c.get(e, "typing").conversation === "conv_g", "typing where the prompt came from"));
    c.step(mux(chunk(3, "All green.")), []);
    c.step(mux(ev(4, "turn_end")), ["persist", "conversation_op", "typing"], (e) =>
      c.check(c.get(e, "conversation_op").conversation === "conv_g", "the reply goes to the prompt's conversation"),
    );
    const own = msg("conv_g", 3, AGENT_MUX, "All green.", { client_msg_id: `turn:${MUX_SESSION}:2` });
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:2`, change: { kind: "message", message: own } }, ["persist"]);
    c.step(live(own), ["conversation_op"], (e) => c.check(opKey(c, e) === "cursor:agent_mux:3", "own message: cursor only"));
    const reply = msg("conv_g", 4, USER_LOCAL, "thanks", { reply_to: { message_id: own.id, part_index: 0 } });
    c.step(live(reply), ["persist", "prompt"], (e) => c.check(c.get(e, "prompt").prompt_id === reply.id, "a reply to the Chief wakes it"));
    cases.push(c.end());
  }

  {
    const dm = summary("conv_dm_ana", [ANA, MUX]);
    const crowded = summary("conv_dm_x", [ANA, ME, MUX]);
    const c = new CaseBuilder("wake DM: a DM with the Chief wakes on every message; a conv_dm_ id with more participants does not");
    boot(c, [summary("conv_a"), dm, crowded]);
    c.step(live(msg("conv_dm_ana", 1, "user_ana", "ping")), ["persist", "prompt"]);
    c.step({ kind: "prompt_settled", prompt_id: msgId("conv_dm_ana", 1) }, ["conversation_op"], (e) =>
      c.check(c.get(e, "conversation_op").conversation === "conv_dm_ana", "a settled prompt moves the inbox on"),
    );
    c.step(live(msg("conv_dm_x", 1, "user_ana", "ping")), ["conversation_op"]);
    cases.push(c.end());
  }

  {
    const answered = msgId("conv_a", 2);
    const c = new CaseBuilder("wake: a retracted message does not wake, an answered one is never prompted again", { answered: [answered] });
    c.feed({ kind: "daemon_connected", conversation: summary("conv_a") });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
    c.feed({ kind: "conversations_listed", conversations: [summary("conv_a")] });
    const messages = [msg("conv_a", 1, USER_LOCAL, "never mind", { retracted_at: ISO }), msg("conv_a", 2, USER_LOCAL, "old question")];
    c.step({ kind: "snapshot", conversation: summary("conv_a"), messages }, ["conversation_op", "conversation_op", "ready"], (e) =>
      c.check(opKey(c, e, 1) === "cursor:agent_mux:2", "the cursor moves past both"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("wake: a conversation without the Chief is ignored; a live message in an unknown conversation fetches its summary first");
    boot(c, [summary("conv_a"), summary("conv_h", [ME])]);
    c.step(live(msg("conv_h", 1, USER_LOCAL, "note to self")), []);
    c.step(live(msg("conv_new", 1, "user_ana", "hi all")), ["fetch_snapshot"], (e) =>
      c.check(c.get(e, "fetch_snapshot").tail === 1, "summary only"),
    );
    c.step({ kind: "snapshot", conversation: summary("conv_new", [ME, ANA, MUX]), messages: [msg("conv_new", 1, "user_ana", "hi all")] }, [
      "conversation_op",
    ]);
    cases.push(c.end());
  }

  return cases;
}

function catchUpCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];

  {
    const c = new CaseBuilder("catch-up: starts after the agent_mux read cursor");
    c.feed({ kind: "daemon_connected", conversation: summary("conv_a", [ME, MUX], 2) });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
    c.feed({ kind: "conversations_listed", conversations: [summary("conv_a", [ME, MUX], 2)] });
    const messages = [1, 2, 3].map((seq) => msg("conv_a", seq, USER_LOCAL, `q${seq}`));
    c.step({ kind: "snapshot", conversation: summary("conv_a", [ME, MUX], 2), messages }, ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === msgId("conv_a", 3), "only the unread message"),
    );
    c.step(mux(ev(1, "user_message", { promptId: msgId("conv_a", 3) })), ["conversation_op", "ready"]);
    cases.push(c.end());
  }

  {
    const conv = (cursor: number) => summary("conv_g", [ME, ANA, MUX], cursor);
    const c = new CaseBuilder("catch-up: pages history back to the first unread message, then handles in order");
    c.feed({ kind: "daemon_connected", conversation: conv(1) });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
    c.feed({ kind: "conversations_listed", conversations: [conv(1)] });
    const all = [1, 2, 3, 4, 5].map((seq) => msg("conv_g", seq, "user_ana", `note ${seq}`));
    all.push(
      msg("conv_g", 6, "user_ana", "@mux sum up", {
        parts: [{ type: "text", text: "@mux sum up", runs: [{ start: 0, length: 4, mention: AGENT_MUX }] }],
      }),
    );
    c.step({ kind: "snapshot", conversation: conv(1), messages: all.slice(4) }, ["fetch_history"], (e) => {
      const history = c.get(e, "fetch_history");
      c.check(history.before_seq === 5 && history.limit === 500, "page before the oldest pending message");
    });
    c.step({ kind: "history", conversation: "conv_g", messages: all.slice(2, 4) }, ["fetch_history"], (e) =>
      c.check(c.get(e, "fetch_history").before_seq === 3, "page again"),
    );
    c.step({ kind: "history", conversation: "conv_g", messages: all.slice(0, 2) }, [
      "persist",
      "conversation_op",
      "conversation_op",
      "conversation_op",
      "conversation_op",
      "prompt",
    ], (e) => {
      c.check(opKey(c, e, 0) === "cursor:agent_mux:2" && opKey(c, e, 3) === "cursor:agent_mux:5", "seq 2..5 in order");
      c.check(c.get(e, "prompt").prompt_id === msgId("conv_g", 6), "the mention wakes");
    });
    c.step(mux(ev(1, "user_message", { promptId: msgId("conv_g", 6) })), ["conversation_op", "ready"]);
    cases.push(c.end());
  }

  {
    const conv = (cursor: number) => summary("conv_g", [ME, ANA, MUX], cursor);
    const c = new CaseBuilder("catch-up: the paging task keeps its own summary copy; a read-cursor change during paging does not change it");
    c.feed({ kind: "daemon_connected", conversation: conv(1) });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
    c.feed({ kind: "conversations_listed", conversations: [conv(1)] });
    const all = [1, 2, 3, 4, 5, 6].map((seq) => msg("conv_g", seq, "user_ana", `note ${seq}`));
    c.step({ kind: "snapshot", conversation: conv(1), messages: all.slice(4) }, ["fetch_history"]);
    c.step({ kind: "conversation_changed", conversation: "conv_g", change: { kind: "read-cursor", participant: AGENT_MUX, seq: 4 } }, []);
    c.step(
      { kind: "history", conversation: "conv_g", messages: all.slice(1, 4) },
      ["conversation_op", "conversation_op", "conversation_op", "conversation_op", "conversation_op", "ready"],
      (e) => c.check(opKey(c, e, 0) === "cursor:agent_mux:2", "cursor ops from the copy's cursor (1), not the changed one (4)"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("catch-up: an empty history page ends paging");
    c.feed({ kind: "daemon_connected", conversation: summary("conv_g", [ME, ANA, MUX]) });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
    c.feed({ kind: "conversations_listed", conversations: [summary("conv_g", [ME, ANA, MUX])] });
    c.step({ kind: "snapshot", conversation: summary("conv_g", [ME, ANA, MUX]), messages: [msg("conv_g", 3, "user_ana", "late")] }, ["fetch_history"]);
    c.step({ kind: "history", conversation: "conv_g", messages: [] }, ["conversation_op", "ready"], (e) =>
      c.check(opKey(c, e) === "cursor:agent_mux:3", "handles what it has"),
    );
    cases.push(c.end());
  }

  {
    const group = (cursor?: number) => summary("conv_g", [ME, ANA, MUX], cursor);
    const c = new CaseBuilder("catch-up: a live message after a gap catches the conversation up");
    boot(c, [group()]);
    c.step(live(msg("conv_g", 1, "user_ana", "one")), ["conversation_op"]);
    c.step(live(msg("conv_g", 3, "user_ana", "three")), ["fetch_snapshot"], (e) =>
      c.check(c.get(e, "fetch_snapshot").tail === 500, "a full catch-up"),
    );
    const messages = [1, 2, 3].map((seq) => msg("conv_g", seq, "user_ana", `n${seq}`));
    c.step({ kind: "snapshot", conversation: group(1), messages }, ["conversation_op", "conversation_op"], (e) =>
      c.check(opKey(c, e, 0) === "cursor:agent_mux:2" && opKey(c, e, 1) === "cursor:agent_mux:3", "the missed message and the live one"),
    );
    c.step(live(msg("conv_g", 3, "user_ana", "three")), [], undefined);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("catch-up: a prompt waiting for acpmux settles when acpmux drops; it is resent on the next connect");
    boot(c);
    const m1 = msg("conv_a", 1, USER_LOCAL, "are you there?");
    c.step(live(m1), ["persist", "prompt"]);
    c.step({ kind: "disconnected", port: "acpmux" }, ["conversation_op"], (e) =>
      c.check(opKey(c, e) === "cursor:agent_mux:1", "the inbox moves on"),
    );
    c.step(live(msg("conv_a", 2, USER_LOCAL, "hello?")), []);
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] }, ["prompt", "list_conversations"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === m1.id, "outstanding prompt resent"),
    );
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a", [ME, MUX], 1)] }, ["fetch_snapshot"]);
    c.step(
      { kind: "snapshot", conversation: summary("conv_a", [ME, MUX], 1), messages: [m1, msg("conv_a", 2, USER_LOCAL, "hello?")] },
      ["persist", "prompt"],
      (e) => c.check(c.get(e, "prompt").prompt_id === msgId("conv_a", 2), "the message sent while acpmux was down"),
    );
    cases.push(c.end((s) => c.check(Object.keys(s.prompts).length === 2, "both prompts outstanding")));
  }

  return cases;
}

function disconnectCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];
  const start = (c: CaseBuilder, conv: Summary) => {
    c.feed({ kind: "daemon_connected", conversation: conv });
    c.feed({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] });
  };

  {
    const c = new CaseBuilder("disconnect: the daemon drops while listing; a late listing is ignored; the reconnect lists again");
    start(c, summary("conv_a"));
    c.step({ kind: "disconnected", port: "daemon" }, []);
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a")] }, []);
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["list_conversations"]);
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a")] }, ["fetch_snapshot"]);
    c.step({ kind: "snapshot", conversation: summary("conv_a"), messages: [] }, ["ready"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("disconnect: the daemon drops during a snapshot and during paging; late answers are ignored");
    const conv = summary("conv_g", [ME, ANA, MUX]);
    start(c, conv);
    c.feed({ kind: "conversations_listed", conversations: [conv] });
    c.step({ kind: "disconnected", port: "daemon" }, []);
    const messages = [1, 2, 3].map((seq) => msg("conv_g", seq, "user_ana", `n${seq}`));
    c.step({ kind: "snapshot", conversation: conv, messages }, []);
    c.step({ kind: "daemon_connected", conversation: conv }, ["list_conversations"]);
    c.step({ kind: "conversations_listed", conversations: [conv] }, ["fetch_snapshot"]);
    c.step({ kind: "snapshot", conversation: conv, messages: messages.slice(2) }, ["fetch_history"]);
    c.step({ kind: "disconnected", port: "daemon" }, []);
    c.step({ kind: "history", conversation: "conv_g", messages: messages.slice(0, 2) }, []);
    c.step({ kind: "daemon_connected", conversation: conv }, ["list_conversations"]);
    c.step({ kind: "conversations_listed", conversations: [conv] }, ["fetch_snapshot"]);
    c.step({ kind: "snapshot", conversation: conv, messages }, ["conversation_op", "conversation_op", "conversation_op", "ready"]);
    cases.push(c.end());
  }

  {
    const conv = summary("conv_g", [ME, ANA, MUX]);
    const c = new CaseBuilder("disconnect: a handling task goes on while the daemon is down; messages it finishes then send no cursor op");
    start(c, conv);
    c.feed({ kind: "conversations_listed", conversations: [conv] });
    const mention = msg("conv_g", 1, "user_ana", "@mux look", {
      parts: [{ type: "text", text: "@mux look", runs: [{ start: 0, length: 4, mention: AGENT_MUX }] }],
    });
    c.step({ kind: "snapshot", conversation: conv, messages: [mention, msg("conv_g", 2, "user_ana", "and this")] }, ["persist", "prompt"]);
    c.step({ kind: "disconnected", port: "daemon" }, []);
    c.step(mux(ev(1, "user_message", { promptId: mention.id })), [], undefined);
    c.step({ kind: "daemon_connected", conversation: conv }, ["list_conversations"]);
    c.step({ kind: "conversations_listed", conversations: [conv] }, ["fetch_snapshot"]);
    c.step({ kind: "snapshot", conversation: conv, messages: [mention, msg("conv_g", 2, "user_ana", "and this")] }, ["ready"], (e) =>
      c.check(!e.some((x) => x.kind === "prompt"), "handled while down: no second prompt"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("refusal: the owner refuses a snapshot, a history page or the list: the task is skipped, the inbox goes on, no reconnect");
    const a = summary("conv_a");
    const g = summary("conv_g", [ME, ANA, MUX]);
    start(c, a);
    c.feed({ kind: "conversations_listed", conversations: [a, g] });
    c.step({ kind: "fetch_refused", conversation: "conv_a", reason: "snapshot_unavailable" } as unknown as Input, ["fetch_snapshot"], (e) =>
      c.check(c.get(e, "fetch_snapshot").conversation === "conv_g", "the next conversation"),
    );
    c.step({ kind: "snapshot", conversation: g, messages: [msg("conv_g", 3, "user_ana", "late")] }, ["fetch_history"]);
    c.step({ kind: "fetch_refused", conversation: "conv_g", reason: "history_unavailable" } as unknown as Input, ["ready"]);
    c.step({ kind: "disconnected", port: "daemon" }, []);
    c.step({ kind: "daemon_connected", conversation: a }, ["list_conversations"]);
    c.step({ kind: "fetch_refused", reason: "list_unavailable" } as unknown as Input, ["ready"]);
    cases.push(c.end());
  }

  return cases;
}

function turnCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];

  {
    const c = new CaseBuilder("turns: a steered prompt joins the running turn; the reply answers the first prompt");
    boot(c);
    const m1 = msg("conv_a", 1, USER_LOCAL, "draft it");
    const m2 = msg("conv_a", 2, USER_LOCAL, "shorter please");
    c.step(live(m1), ["persist", "prompt"]);
    c.step(mux(ev(1, "user_message", { promptId: m1.id })), ["conversation_op"]);
    c.step(mux(ev(2, "turn_started")), ["typing"]);
    c.step(live(m2), ["persist", "prompt"]);
    c.step(mux(ev(3, "user_message", { promptId: m2.id, steer: true })), ["conversation_op"]);
    c.step(mux(chunk(4, "Short draft.")), []);
    c.step(mux(ev(5, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const state = c.persisted(e);
      c.check(state.answered.join() === m1.id && state.prompts[m2.id] !== undefined, "only the turn's prompt is answered");
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: a queued prompt is accepted at once and becomes the next turn; the outbox sends one op at a time");
    boot(c);
    const m1 = msg("conv_a", 1, USER_LOCAL, "first");
    const m2 = msg("conv_a", 2, USER_LOCAL, "second");
    c.step(live(m1), ["persist", "prompt"]);
    c.step(mux(ev(1, "user_message", { promptId: m1.id })), ["conversation_op"]);
    c.step(mux(ev(2, "turn_started")), ["typing"]);
    c.step(live(m2), ["persist", "prompt"]);
    c.step(mux(ev(3, "queued", { promptId: m2.id })), ["conversation_op"], (e) =>
      c.check(opKey(c, e) === "cursor:agent_mux:2", "queued is accepted"),
    );
    c.step(mux(chunk(4, "one")), []);
    c.step(mux(ev(5, "turn_end")), ["persist", "conversation_op", "typing"]);
    c.step(mux(ev(6, "user_message", { promptId: m2.id })), []);
    c.step(mux(ev(7, "turn_started")), ["typing"]);
    c.step(mux(chunk(8, "two")), []);
    c.step(mux(ev(9, "turn_end")), ["persist", "typing"], (e) =>
      c.check(c.persisted(e).outbox.length === 2, "the second reply waits for the first op's result"),
    );
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:2` }, ["persist", "conversation_op"], (e) =>
      c.check(opKey(c, e) === `turn:${MUX_SESSION}:7`, "then the next one"),
    );
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:7` }, ["persist"]);
    cases.push(c.end((s) => c.check(s.answered.join() === `${m1.id},${m2.id}`, "both answered")));
  }

  {
    const c = new CaseBuilder("turns: turn_error text (string, number, object, missing, empty) and a turn with no prompt goes to the default conversation");
    boot(c);
    const fail = (seq: number, msg: Record<string, unknown>, kinds: Kind[], text?: string) => {
      c.step(mux(ev(seq, "turn_started")), ["typing"]);
      c.step(mux(ev(seq + 1, "turn_error", msg)), kinds, (e) => {
        if (text === undefined) return;
        const op = c.get(e, "conversation_op");
        c.check(op.conversation === "conv_a", "default conversation");
        c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === text, `error text ${text}`);
      });
      if (kinds.includes("conversation_op")) c.feed({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:${seq}` });
    };
    fail(1, { error: "boom" }, ["persist", "conversation_op", "typing"], "(turn failed: boom)");
    fail(3, { error: 42 }, ["persist", "conversation_op", "typing"], "(turn failed: 42)");
    fail(5, { error: { code: "x" } }, ["persist", "conversation_op", "typing"], "(turn failed: [object Object])");
    fail(7, { reason: "overloaded", code: 529, detail: { z: 1, a: [{ d: 1, c: 2 }] } }, ["persist", "conversation_op", "typing"], '(turn failed: {"code":529,"detail":{"a":[{"c":2,"d":1}],"z":1},"reason":"overloaded"})');
    fail(9, { error: "" }, ["persist", "typing"]);
    c.step(mux(ev(11, "turn_started")), ["typing"]);
    c.step(mux(chunk(12, "partial answer")), []);
    c.step(mux(ev(13, "turn_error", { error: "cut off" })), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "partial answer", "text wins over the error");
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: an empty promptId is no prompt id (no acceptance, nothing answered); non-string chunk text is skipped");
    boot(c);
    c.step(mux(ev(1, "user_message", { promptId: "" })), []);
    c.step(mux(ev(2, "turn_started")), ["typing"]);
    c.step(mux(ev(3, "agent_message_chunk", { params: { update: { content: { type: "text", text: 5 } } } }, "agent")), []);
    c.step(mux(chunk(4, "only text")), []);
    c.step(mux(ev(5, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.conversation === "conv_a" && op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "only text", "default conversation, text only");
      c.check(c.persisted(e).answered.length === 0, "nothing answered");
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: an event whose seq or at is not a non-negative integer is dropped with a log");
    boot(c);
    c.step(mux(ev(1, "turn_started")), ["typing"]);
    c.step(mux({ ...chunk(2, "float seq "), seq: 2.5 }), []);
    c.step(mux({ ...chunk(2, "float at "), at: 7.25 }), []);
    c.step(mux({ ...chunk(2, "negative seq "), seq: -1 }), []);
    c.step(mux(chunk(3, "good")), []);
    c.step(mux(ev(4, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "good", "only the valid chunk");
    });
    cases.push(c.end());
  }

  {
    // JSON has one number type: `1.0` is the value 1, as JavaScript's JSON.parse reads it.
    // A reader that keeps an integer-valued float apart (serde_json) must read it as that integer.
    const c = new CaseBuilder("wire counts: a seq or at written as an integer-valued float (1.0, 3e0) is that integer");
    boot(c);
    const wire = (seq: string, kind: string, dir: string, msg: string, at = "") =>
      `{"kind":"acpmux_event","event":{"sessionId":"${MUX_SESSION}","seq":${seq},${at ? `"at":${at},` : ""}"dir":"${dir}","kind":"${kind}","msg":${msg}}}`;
    const text = (t: string) => `{"params":{"update":{"content":{"type":"text","text":"${t}"}}}}`;
    c.stepText(wire("1.0", "turn_started", "mux", "{}"), ["typing"]);
    c.stepText(wire("2.0", "agent_message_chunk", "agent", text("float "), `${T0 + 2}.0`), []);
    c.stepText(wire("3e0", "agent_message_chunk", "agent", text("typed")), []);
    c.stepText(wire("2.0", "agent_message_chunk", "agent", text(" replayed")), []);
    // Not counts, whatever the text: a fraction, a negative, above 2^53 - 1 (dropped with a log).
    for (const bad of ["4.5", "-4.0", "9007199254740992.0"]) c.stepText(wire(bad, "agent_message_chunk", "agent", text(" dropped")), []);
    c.stepText(wire("4.0", "turn_end", "mux", "{}"), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === `turn:${MUX_SESSION}:1`, `key from seq 1, got ${op.idempotency_key}`);
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "float typed", "seq 2.0 at or below the cursor is a replay");
      c.check(c.persisted(e).acpmuxSeq === 4, "cursor 4");
    });
    // The largest count, written as a float, is still a count.
    c.stepText(wire("9007199254740991.0", "turn_started", "mux", "{}"), ["typing"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("wire counts: a log_id written as an integer-valued float is that identity", { defaultConversation: "conv_a" });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.stepText(
      `{"kind":"acpmux_connected","session_id":"${MUX_SESSION}","sessions":[],"events":[],"log_id":${T0 + 500}.0,"created":true}`,
      ["persist", "list_conversations"],
      (e) => c.check((c.persisted(e) as HostStateData & { acpmuxLog?: number }).acpmuxLog === T0 + 500, "identity recorded"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: an event without seq or msg folds as seq 0 and {}; an empty default conversation is none");
    boot(c);
    c.step(mux(ev(1, "turn_started")), ["typing"]);
    const noSeq = { sessionId: MUX_SESSION, dir: "agent", kind: "agent_message_chunk", msg: { params: { update: { content: { type: "text", text: "unnumbered" } } } } };
    c.step(mux(noSeq as unknown as AcpmuxEvent), []);
    c.step(mux({ sessionId: MUX_SESSION, seq: 2, dir: "mux", kind: "queued" } as unknown as AcpmuxEvent), []);
    c.step(mux(ev(3, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "unnumbered", "the unnumbered chunk counts");
    });
    cases.push(c.end());
    const empty = new CaseBuilder("turns: with an empty default conversation a turn without a prompt posts nothing", { defaultConversation: "" });
    empty.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [ev(1, "turn_started"), chunk(2, "nowhere"), ev(3, "turn_end")] },
      ["persist"],
      (e) => empty.check(empty.persisted(e).outbox.length === 0, "no reply"),
    );
    cases.push(empty.end());
  }

  {
    const c = new CaseBuilder("turns: an attach replay at or below the saved cursor is ignored; newer events fold", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 4,
      answered: [msgId("conv_a", 1)],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a", [ME, MUX], 1) }, []);
    const events = [
      ev(1, "user_message", { promptId: msgId("conv_a", 1) }),
      ev(2, "turn_started"),
      chunk(3, "old reply"),
      ev(4, "turn_end"),
      ev(5, "turn_started"),
      chunk(6, "late reply"),
      ev(7, "turn_end"),
    ];
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events },
      ["persist", "typing", "conversation_op", "typing", "list_conversations"],
      (e) => {
        c.check(opKey(c, e) === `turn:${MUX_SESSION}:5`, "only the new turn");
        c.check(c.persisted(e).acpmuxSeq === 7, "cursor advanced");
      },
    );
    cases.push(c.end());
  }

  {
    const epoch = T0 + 500;
    const c = new CaseBuilder("turns: after cursor_reset the promptless replay posts nothing (the cursor moves) and later reply keys carry an epoch", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 9,
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [{ ...ev(1, "turn_started"), at: epoch }, { ...chunk(2, "again"), at: epoch + 1 }, { ...ev(3, "turn_end"), at: epoch + 2 }],
        cursor_reset: true,
      },
      ["persist", "list_conversations"],
      (e) => {
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number };
        c.check(state.acpmuxSeq === 3 && state.outbox.length === 0, "the cursor moves, nothing is posted");
        c.check(state.acpmuxEpoch === epoch + 1, `the first reset's epoch is identity + 1 (downgrade-safe), got ${state.acpmuxEpoch}`);
      },
    );
    c.step(mux(ev(4, "turn_started")), ["typing"]);
    c.step(mux(chunk(5, "later")), []);
    c.step(mux(ev(6, "turn_end")), ["persist", "conversation_op", "typing"], (e) =>
      c.check(opKey(c, e) === `turn:${MUX_SESSION}:${epoch + 1}:4`, "a live turn after the reset gets the epoch key"),
    );
    cases.push(c.end());
  }

  {
    const first = T0 + 500;
    const c = new CaseBuilder("log identity: a repeated import of the same bundle gets a new epoch (previous + 1), so new turns never reuse keys", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 9,
      acpmuxEpoch: first,
      acpmuxLog: first,
    } as Partial<HostStateData>);
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [{ ...ev(1, "turn_started"), at: first }, chunk(2, "bundle turn"), ev(3, "turn_end")],
        cursor_reset: true,
        log_id: first,
      } as Input,
      ["persist", "list_conversations"],
      (e) => {
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number; acpmuxLog?: number };
        c.check(state.acpmuxEpoch === first + 1, `epoch is previous + 1, got ${state.acpmuxEpoch}`);
        c.check(state.acpmuxLog === first && state.outbox.length === 0, "same log identity, nothing posted");
      },
    );
    c.step(mux(ev(4, "turn_started")), ["typing"]);
    c.step(mux(chunk(5, "new turn")), []);
    c.step(mux(ev(6, "turn_end")), ["persist", "conversation_op", "typing"], (e) =>
      c.check(opKey(c, e) === `turn:${MUX_SESSION}:${first + 1}:4`, `new key, got ${opKey(c, e)}`),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("log identity: a legacy host.json (no acpmuxLog) for the same session adopts the identity without a reset", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 4,
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [ev(5, "turn_started"), chunk(6, "after upgrade"), ev(7, "turn_end")], log_id: T0 + 500 } as Input,
      ["persist", "typing", "conversation_op", "typing", "list_conversations"],
      (e) => {
        c.check(opKey(c, e) === `turn:${MUX_SESSION}:5`, `plain key, got ${opKey(c, e)}`);
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number; acpmuxLog?: number };
        c.check(state.acpmuxEpoch === undefined && state.acpmuxLog === T0 + 500 && state.acpmuxSeq === 7, "adopted, no reset");
      },
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("log identity: a log_id that is not a non-negative integer is ignored with a log", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 4,
      acpmuxLog: T0 + 500,
    } as Partial<HostStateData>);
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [], log_id: 2.5 } as unknown as Input, [], undefined);
    cases.push(c.end((s) => c.check((s as HostStateData & { acpmuxLog?: number }).acpmuxLog === T0 + 500, "identity kept")));
  }

  {
    const created = T0 + 10;
    const c = new CaseBuilder("log identity: a session the host created keeps plain keys, even though its log already holds the created event", {
      defaultConversation: "conv_a",
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [{ ...ev(1, "created", { policy: "approve-all" }), at: created }],
        log_id: created,
        created: true,
      } as Input,
      ["persist", "list_conversations"],
      (e) => {
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number; acpmuxLog?: number };
        c.check(state.acpmuxEpoch === undefined && state.acpmuxLog === created, "no epoch, identity recorded");
      },
    );
    c.step(mux(ev(2, "turn_started")), ["typing"]);
    c.step(mux(chunk(3, "hello")), []);
    c.step(mux(ev(4, "turn_end")), ["persist", "conversation_op", "typing"], (e) =>
      c.check(opKey(c, e) === `turn:${MUX_SESSION}:2`, `plain key, got ${opKey(c, e)}`),
    );
    cases.push(c.end());
  }

  {
    const first = T0 + 500;
    const c = new CaseBuilder("log identity: after a lost host.json a non-empty log is a reset: its replay posts nothing and new keys get an epoch from now", {
      defaultConversation: "conv_a",
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    let connectedAt = 0;
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [
          { ...ev(1, "user_message", { promptId: "m_lost" }), at: first },
          ev(2, "turn_started"),
          chunk(3, "old answer"),
          ev(4, "turn_end"),
          ev(5, "turn_started"),
          chunk(6, "old promptless"),
          ev(7, "turn_end"),
        ],
        log_id: first,
      } as Input,
      ["persist", "list_conversations"],
      (e) => {
        connectedAt = c.now;
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number; acpmuxLog?: number };
        c.check(state.outbox.length === 0 && state.acpmuxSeq === 7, "nothing posted, cursor moved");
        c.check(state.acpmuxEpoch === c.now && state.acpmuxLog === first, `epoch from now, got ${state.acpmuxEpoch}`);
      },
    );
    c.step(mux(ev(8, "turn_started")), ["typing"]);
    c.step(mux(chunk(9, "fresh")), []);
    c.step(mux(ev(10, "turn_end")), ["persist", "conversation_op", "typing"], (e) =>
      c.check(opKey(c, e) === `turn:${MUX_SESSION}:${connectedAt}:8`, `epoch key, got ${opKey(c, e)}`),
    );
    cases.push(c.end());
  }

  {
    const first = T0 + 500;
    const c = new CaseBuilder("log identity: the same log keeps plain keys; a different log for the same session is a reset", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 4,
      acpmuxLog: first,
    } as Partial<HostStateData>);
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [ev(5, "turn_started"), chunk(6, "same log"), ev(7, "turn_end")], log_id: first } as Input,
      ["persist", "typing", "conversation_op", "typing", "list_conversations"],
      (e) => c.check(opKey(c, e) === `turn:${MUX_SESSION}:5`, "plain key"),
    );
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:5` }, ["persist"]);
    c.step({ kind: "disconnected", port: "acpmux" }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [{ ...ev(1, "turn_started"), at: T0 + 900 }, chunk(2, "other log"), ev(3, "turn_end")],
        log_id: T0 + 900,
      } as Input,
      ["persist"],
      (e) => {
        const state = c.persisted(e) as HostStateData & { acpmuxEpoch?: number; acpmuxLog?: number };
        c.check(state.acpmuxEpoch === T0 + 901 && state.acpmuxLog === T0 + 900 && state.outbox.length === 0, "reset by identity, epoch identity + 1");
      },
    );
    cases.push(c.end());
  }

  {
    const answered = msgId("conv_a", 1);
    const c = new CaseBuilder("turns: a cursor_reset replay of a turn whose prompt is answered posts nothing, even with the prompt recorded again", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 9,
      answered: [answered],
      prompts: { [answered]: { conversation: "conv_a", text: "[conversation conv_a from Me] hi", seq: 1 } },
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [{ ...ev(1, "user_message", { promptId: answered }), at: T0 + 800 }, ev(2, "turn_started"), chunk(3, "again"), ev(4, "turn_end")],
        cursor_reset: true,
      },
      ["persist", "list_conversations"],
      (e) => c.check(c.persisted(e).outbox.length === 0 && c.persisted(e).prompts[answered] === undefined, "no second reply; the entry is settled"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: a replayed turn of an answered prompt (conv_b) posts nothing, not even to the default conversation", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      acpmuxSeq: 9,
      answered: [msgId("conv_b", 1)],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [],
        events: [
          { ...ev(1, "user_message", { promptId: msgId("conv_b", 1) }), at: T0 + 700 },
          ev(2, "turn_started"),
          chunk(3, "the old answer"),
          ev(4, "turn_end"),
        ],
        cursor_reset: true,
      },
      ["persist", "list_conversations"],
      (e) => c.check(c.persisted(e).outbox.length === 0, "no reply queued"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: a new mux session resets the cursor; outstanding prompts are resent in sorted id order", {
      defaultConversation: "conv_a",
      muxSessionId: "s_old",
      acpmuxSeq: 9,
      prompts: {
        "msg_b": { conversation: "conv_a", text: "second", seq: 2 },
        "child:s_c:1": { conversation: "conv_a", text: "[mux-event] child c finished: ok" },
        "msg_a": { conversation: "conv_a", text: "first", seq: 1 },
      },
    });
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] }, ["persist", "prompt", "prompt", "prompt"], (e) => {
      const state = c.persisted(e);
      c.check(state.muxSessionId === MUX_SESSION && state.acpmuxSeq === 0, "new session, cursor 0");
      const ids = e.filter((x) => x.kind === "prompt").map((x) => (x as Of<"prompt">).prompt_id);
      c.check(ids.join() === "child:s_c:1,msg_a,msg_b", `sorted resend order: ${ids.join()}`);
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: outstanding prompts are resent in the order they were recorded (order, absent = 0, then id); a new prompt gets the next order", {
      defaultConversation: "conv_a",
      muxSessionId: "s_old",
      prompts: {
        msg_a: { conversation: "conv_a", text: "second", order: 2 },
        msg_b: { conversation: "conv_a", text: "first", order: 1 },
        old: { conversation: "conv_a", text: "from an older host.json" },
      },
    } as Partial<HostStateData>);
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] }, ["persist", "prompt", "prompt", "prompt"], (e) => {
      const ids = e.filter((x) => x.kind === "prompt").map((x) => (x as Of<"prompt">).prompt_id);
      c.check(ids.join() === "old,msg_b,msg_a", `recorded order, got ${ids.join()}`);
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["list_conversations"]);
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a")] }, ["fetch_snapshot"]);
    const m1 = msg("conv_a", 1, USER_LOCAL, "new");
    c.step({ kind: "snapshot", conversation: summary("conv_a"), messages: [m1] }, ["persist", "prompt"], (e) => {
      const entry = c.persisted(e).prompts[m1.id] as { order?: number };
      c.check(entry.order === 3, `next order, got ${entry.order}`);
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("turns: recording an outstanding prompt again (a repeated permission) keeps its order");
    boot(c, [summary("conv_a")], [session("s_w", "writer", "waiting")]);
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "p1", request: {} }, ["persist", "conversation_op", "prompt"]);
    c.step(live(msg("conv_a", 1, USER_LOCAL, "meanwhile")), ["persist", "prompt"]);
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "p1", request: {} }, ["persist", "prompt"], (e) => {
      const order = (c.persisted(e).prompts["perm:s_w:p1"] as { order?: number }).order;
      c.check(order === 1, `the first order stays, got ${order}`);
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("typing: no typing while the daemon is down; the reply waits in the outbox; acpmux loss turns typing off", {
      defaultConversation: "conv_a",
    });
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [ev(1, "turn_started"), chunk(2, "offline reply"), ev(3, "turn_end")] },
      ["persist"],
      (e) => c.check(c.persisted(e).outbox.length === 1, "queued"),
    );
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op", "list_conversations"]);
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:1` }, ["persist"]);
    c.step({ kind: "conversations_listed", conversations: [summary("conv_a")] }, ["fetch_snapshot"]);
    c.step({ kind: "snapshot", conversation: summary("conv_a"), messages: [] }, ["ready"]);
    c.step(mux(ev(4, "turn_started")), ["typing"]);
    c.step({ kind: "disconnected", port: "acpmux" }, ["typing"], (e) => c.check(!c.get(e, "typing").on, "typing off"));
    cases.push(c.end());
  }

  return cases;
}

function outboxCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];
  const reply = (key: string, text: string) => ({
    conversation: "conv_a",
    idempotency_key: key,
    op: { kind: "message.send" as const, client_msg_id: key, parts: [{ type: "text" as const, text }] },
  });

  {
    const c = new CaseBuilder("outbox: agent_rate is retried once after the gap, then dropped", {
      defaultConversation: "conv_a",
      outbox: [reply("turn:s_mux:2", "Hi there")],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op"]);
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2", reason: "conversation-op: agent_rate (conversation_rejected)" }, ["persist", "arm_timer"], (e) => {
      const entry = c.persisted(e).outbox[0];
      c.check(entry.rateRetried === true && entry.notBefore === c.now + 2_200, "retry after the 2.2 s gap");
      c.check(c.get(e, "arm_timer").at === c.now + 2_250 && c.get(e, "arm_timer").key === "outbox", "one-shot timer");
    });
    c.step({ kind: "timer", key: "outbox" }, ["arm_timer"], (e) => c.check(c.get(e, "arm_timer").at === c.now + 1_250, "an early fire arms the timer again"), 1_000);
    c.step({ kind: "timer", key: "outbox" }, ["conversation_op"], undefined, 1_250);
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2", reason: "conversation-op: agent_rate (conversation_rejected)" }, ["persist"], (e) =>
      c.check(c.persisted(e).outbox.length === 0, "dropped after one retry"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("outbox: agent_budget is dropped at once and the next entry goes out", {
      defaultConversation: "conv_a",
      outbox: [reply("turn:s_mux:2", "one"), reply("turn:s_mux:6", "two")],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op"]);
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2", reason: "conversation-op: agent_budget (conversation_rejected)" }, ["persist", "conversation_op"], (e) =>
      c.check(opKey(c, e) === "turn:s_mux:6", "next entry"),
    );
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:6" }, ["persist"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("outbox: actor_mismatch reconnects the daemon and keeps the entry; it is sent again after the reconnect", {
      defaultConversation: "conv_a",
      outbox: [reply("turn:s_mux:2", "Hi there")],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op"]);
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2", reason: "conversation-op: actor_mismatch (conversation_rejected)" }, ["reconnect"], (e) =>
      c.check(c.get(e, "reconnect").port === "daemon", "daemon port"),
    );
    c.step({ kind: "disconnected", port: "daemon" }, []);
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op"]);
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2" }, ["persist"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("outbox: a not_before in the future at connect arms the timer again (once); a connect while up drops the inflight op", {
      defaultConversation: "conv_a",
      outbox: [{ ...reply("turn:s_mux:2", "Hi there"), rateRetried: true, notBefore: T0 + 5_000 }],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["arm_timer"], (e) =>
      c.check(c.get(e, "arm_timer").at === T0 + 5_050 && c.get(e, "arm_timer").key === "outbox", "armed after a restart"),
    );
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    c.step({ kind: "timer", key: "outbox" }, ["conversation_op"], undefined, 5_100);
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["conversation_op"], (e) =>
      c.check(opKey(c, e) === "turn:s_mux:2", "the old connection's op is sent again"),
    );
    c.step({ kind: "op_result", idempotency_key: "turn:s_mux:2" }, ["persist"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("outbox: an edit of a work card whose send was never confirmed is dropped; a confirmed one gets its message id", {
      defaultConversation: "conv_a",
      children: {
        s_x: { conversation: "conv_a", name: "x", status: "done", edits: 1 },
        s_y: { conversation: "conv_a", name: "y", status: "done", messageId: "m_card_y", edits: 1 },
      },
      outbox: [
        { conversation: "conv_a", idempotency_key: "work:s_x:1", child: "s_x", op: { kind: "message.edit", message_id: "", parts: [{ type: "work", session: "x", status: "done" }] } },
        { conversation: "conv_a", idempotency_key: "work:s_y:1", child: "s_y", op: { kind: "message.edit", message_id: "", parts: [{ type: "work", session: "y", status: "done" }] } },
      ],
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, ["persist", "conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "work:s_y:1" && op.op.kind === "message.edit" && op.op.message_id === "m_card_y", "message id filled in");
    });
    c.step({ kind: "op_result", idempotency_key: "cursor:agent_mux:9", reason: "conversation-op: not_participant (conversation_rejected)" }, []);
    c.step({ kind: "op_result", idempotency_key: "work:s_y:1" }, ["persist"]);
    cases.push(c.end());
  }

  return cases;
}

function childCases(): CorpusCase[] {
  const cases: CorpusCase[] = [];

  {
    const c = new CaseBuilder("children: on reconnect a child in waiting whose session is ready finishes", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      children: { s_w: { conversation: "conv_a", name: "writer", status: "waiting", messageId: "m_w", edits: 1 } },
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    const ready = session("s_w", "writer", "ready", { turnCount: 2, lastSeq: 8 });
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [ready], events: [] }, ["fetch_child_events", "list_conversations"]);
    c.step({ kind: "child_events", session_id: "s_w", events: [] }, ["persist", "prompt", "conversation_op"], (e) => {
      c.check(c.get(e, "prompt").prompt_id === "child:s_w:2", "finished");
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.edit" && op.op.message_id === "m_w" && op.op.parts[0].type === "work" && op.op.parts[0].status === "done", "card done");
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a child whose permission was denied (waiting -> ready) finishes, as on reconnect");
    boot(c);
    c.step({ kind: "session_changed", session: session("s_d", "deny", "running") }, ["persist", "conversation_op"]);
    const card = msg("conv_a", 1, AGENT_MUX, "", { id: "m_d", client_msg_id: "work:s_d", parts: [{ type: "work", session: "deny", status: "running" }] });
    c.step({ kind: "op_result", idempotency_key: "work:s_d", change: { kind: "message", message: card } }, ["persist"]);
    c.step({ kind: "permission_pending", session_id: "s_d", permission_id: "p1", request: {} }, ["persist", "conversation_op", "prompt"]);
    c.step({ kind: "session_changed", session: session("s_d", "deny", "waiting") }, []);
    c.step({ kind: "session_changed", session: session("s_d", "deny", "ready", { turnCount: 1, lastSeq: 6 }) }, ["fetch_child_events"]);
    c.step({ kind: "child_events", session_id: "s_d", events: [] }, ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === "child:s_d:1", "finished"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a child first seen ready gets a done card");
    boot(c);
    c.step({ kind: "session_changed", session: session("s_n", "late", "ready", { turnCount: 1 }) }, ["persist", "conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.send" && op.op.parts[0].type === "work" && op.op.parts[0].status === "done", "done card");
      c.check(c.persisted(e).children.s_n.status === "done", "record done");
    });
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a session without stateSeq or turnCount finishes as child:<id>:0");
    boot(c);
    const { stateSeq: _drop, ...noSeq } = session("s_q", "quiet", "running");
    void _drop;
    c.step({ kind: "session_changed", session: noSeq as SessionSummary }, ["persist", "conversation_op"]);
    c.step({ kind: "session_changed", session: { ...noSeq, status: "idle" } as SessionSummary }, ["fetch_child_events"]);
    c.step({ kind: "child_events", session_id: "s_q", events: [] }, ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === "child:s_q:0", `got ${c.get(e, "prompt").prompt_id}`),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: changes of a child whose finish waits for its events are held and replayed in order");
    boot(c);
    c.step({ kind: "session_changed", session: session("s_c", "fixer", "running") }, ["persist", "conversation_op"]);
    const card = msg("conv_a", 1, AGENT_MUX, "", { id: "m_card", client_msg_id: "work:s_c", parts: [{ type: "work", session: "fixer", status: "running" }] });
    c.step({ kind: "op_result", idempotency_key: "work:s_c", change: { kind: "message", message: card } }, ["persist"]);
    c.step({ kind: "session_changed", session: session("s_c", "fixer", "ready", { turnCount: 1, lastSeq: 4 }) }, ["fetch_child_events"]);
    c.step({ kind: "session_changed", session: session("s_c", "fixer", "running", { turnCount: 1, lastSeq: 5 }) }, []);
    c.step({ kind: "session_changed", session: session("s_c", "fixer", "ready", { turnCount: 2, lastSeq: 9 }) }, []);
    const turn = (text: string) => [ev(1, "turn_started", {}, "mux", "s_c"), chunk(2, text, "s_c"), ev(3, "turn_end", {}, "mux", "s_c")];
    c.step({ kind: "child_events", session_id: "s_c", events: turn("first done") }, ["persist", "prompt", "conversation_op", "fetch_child_events"], (e) => {
      c.check(c.get(e, "prompt").prompt_id === "child:s_c:1", "the first finish");
      c.check(opKey(c, e) === "work:s_c:1", "its card edit");
      c.check(c.get(e, "fetch_child_events").after === 4, "the held turn end fetches after the first turn");
      c.check(c.persisted(e).outbox.length === 2, "the held running edit is queued behind");
    });
    c.step({ kind: "child_events", session_id: "s_c", events: turn("second done") }, ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === "child:s_c:2", "the second finish"),
    );
    cases.push(c.end((s) => c.check(s.children.s_c.edits === 3 && s.children.s_c.status === "done", "three edits, done")));
  }

  {
    const c = new CaseBuilder("children: on acpmux connect a pending permission whose session is no longer waiting is dropped (answered meanwhile)");
    boot(c);
    c.step({ kind: "permission_pending", session_id: "s_v", permission_id: "p1", request: {} }, ["fetch_sessions"]);
    c.step({ kind: "disconnected", port: "acpmux" }, []);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [session("s_v", "viewer", "running")], events: [] },
      ["list_conversations"],
      (e) => c.check(!e.some((x) => x.kind === "prompt"), "no stale permission prompt"),
    );
    cases.push(c.end((s) => c.check(s.prompts["perm:s_v:p1"] === undefined && s.children.s_v === undefined, "nothing recorded")));
  }

  {
    const c = new CaseBuilder("children: on acpmux connect a permission prompt whose turn is running is kept (not resent), so its reply still posts", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      prompts: { "perm:s_w:p1": { conversation: "conv_a", text: "[mux-event] child writer asks", order: 1 } },
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    // The mux answered the permission during its turn, so the child no longer waits; the turn still runs.
    c.step(
      {
        kind: "acpmux_connected",
        session_id: MUX_SESSION,
        sessions: [session("s_w", "writer", "running")],
        events: [ev(1, "user_message", { promptId: "perm:s_w:p1" }), ev(2, "turn_started"), chunk(3, "allowed it")],
      },
      ["persist", "typing", "list_conversations"],
      (e) => {
        c.check(!e.some((x) => x.kind === "prompt"), "the running prompt is not resent");
        c.check(c.persisted(e).prompts["perm:s_w:p1"] !== undefined, "the running prompt is kept");
      },
    );
    c.step(mux(ev(4, "turn_end")), ["persist", "conversation_op", "typing"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.conversation === "conv_a" && op.op.kind === "message.send" && op.op.parts[0].type === "text" && op.op.parts[0].text === "allowed it", "the reply posts");
    });
    cases.push(c.end((s) => c.check(s.prompts["perm:s_w:p1"] === undefined && s.answered.includes("perm:s_w:p1"), "answered")));
  }

  {
    const c = new CaseBuilder("children: on acpmux connect an outstanding permission prompt whose session is not waiting is dropped, not resent", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      prompts: {
        "perm:s_w:p1": { conversation: "conv_a", text: "still asking", order: 1 },
        "perm:s_x:p2": { conversation: "conv_a", text: "answered meanwhile", order: 2 },
        "perm:s_gone:p3": { conversation: "conv_a", text: "session gone", order: 3 },
      },
    } as Partial<HostStateData>);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [session("s_w", "writer", "waiting"), session("s_x", "other", "running")], events: [] },
      ["persist", "prompt"],
      (e) => {
        c.check(c.get(e, "prompt").prompt_id === "perm:s_w:p1", "only the waiting session's prompt is resent");
        c.check(Object.keys(c.persisted(e).prompts).join() === "perm:s_w:p1", "the stale ones are dropped");
      },
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a stale permission prompt is matched by its exact session (the permission id is after the last ':'): sessions s and s:x", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      prompts: {
        "perm:s:p2": { conversation: "conv_a", text: "session s, waiting", order: 1 },
        "perm:s:x:p1": { conversation: "conv_a", text: "session s:x, answered", order: 2 },
      },
    } as Partial<HostStateData>);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [session("s", "one", "waiting"), session("s:x", "two", "running")], events: [] },
      ["persist", "prompt"],
      (e) => {
        c.check(c.get(e, "prompt").prompt_id === "perm:s:p2", "session s keeps its prompt");
        c.check(Object.keys(c.persisted(e).prompts).join() === "perm:s:p2", "perm:s:x:p1 belongs to s:x, which is not waiting");
      },
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a pending permission survives a failed sessions fetch and an acpmux reconnect, then is answered");
    boot(c);
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "p1", request: {} }, ["fetch_sessions"]);
    c.step({ kind: "sessions", sessions: [], failed: true } as unknown as Input, []);
    const writer = session("s_w", "writer", "waiting");
    c.step({ kind: "sessions", sessions: [writer] }, ["persist", "conversation_op", "prompt"], (e) =>
      c.check(c.get(e, "prompt").prompt_id === "perm:s_w:p1", "answered after the retry"),
    );
    c.step({ kind: "permission_pending", session_id: "s_v", permission_id: "p2", request: {} }, ["fetch_sessions"]);
    c.step({ kind: "disconnected", port: "acpmux" }, []);
    c.step(
      { kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [writer, session("s_v", "viewer", "waiting")], events: [] },
      ["persist", "prompt", "prompt", "list_conversations"],
      (e) => {
        const ids = e.filter((x) => x.kind === "prompt").map((x) => (x as Of<"prompt">).prompt_id);
        c.check(ids.join() === "perm:s_w:p1,perm:s_v:p2", `resent, then the kept permission: ${ids.join()}`);
      },
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a permission option without an optionId prints an empty id; nested rawInput keys are sorted");
    boot(c, [summary("conv_a")], [session("s_w", "writer", "running")]);
    const request = {
      toolCall: { title: 7, rawInput: { z: 1, b: { y: true, a: [{ d: 1, c: 2 }] }, "10": "x", "2": "y" } },
      options: [{ name: "Allow" }, { optionId: "deny", kind: "reject_once" }, "junk"],
    };
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "p1", request }, ["persist", "conversation_op", "prompt"], (e) =>
      c.check(
        c.get(e, "prompt").text.startsWith(
          '[mux-event] child writer asks permission: a tool call\nInput: {"10":"x","2":"y","b":{"a":[{"c":2,"d":1}],"y":true},"z":1}\nOptions:  (Allow), deny (reject_once),  ()\n',
        ),
        "string-only fields, canonical rawInput",
      ),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("acpmux connected while up counts as a disconnect first: the waiting prompt settles and is resent");
    boot(c);
    const m1 = msg("conv_a", 1, USER_LOCAL, "hello");
    c.step(live(m1), ["persist", "prompt"]);
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [], events: [] }, ["conversation_op", "prompt", "list_conversations"], (e) =>
      c.check(opKey(c, e) === "cursor:agent_mux:1" && c.get(e, "prompt").prompt_id === m1.id, "settled, then resent"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a child started during a turn gets a work card there; its turn end prompts the Chief and marks the card done");
    boot(c);
    const m1 = msg("conv_a", 1, USER_LOCAL, "spawn a fixer");
    c.step(live(m1), ["persist", "prompt"]);
    c.step(mux(ev(1, "user_message", { promptId: m1.id })), ["conversation_op"]);
    c.step(mux(ev(2, "turn_started")), ["typing"]);
    const running = session("s_c", "fixer", "running", { lastPrompt: "fix the parser bug" });
    c.step({ kind: "session_changed", session: running }, ["persist", "conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "work:s_c" && op.conversation === "conv_a", "card key and conversation");
      c.check(
        op.op.kind === "message.send" && op.op.parts[0].type === "work" && op.op.parts[0].status === "running" && op.op.parts[0].preview === "fix the parser bug",
        "running card with the prompt as preview",
      );
    });
    const card = msg("conv_a", 2, AGENT_MUX, "", { id: "m_card", client_msg_id: "work:s_c", parts: [{ type: "work", session: "fixer", status: "running" }] });
    c.step({ kind: "op_result", idempotency_key: "work:s_c", change: { kind: "message", message: card } }, ["persist"], (e) =>
      c.check(c.persisted(e).children.s_c.messageId === "m_card", "card message id recorded"),
    );
    c.step({ kind: "session_changed", session: running }, []);
    c.step(mux(chunk(3, "Started a fixer.")), []);
    c.step(mux(ev(4, "turn_end")), ["persist", "conversation_op", "typing"]);
    c.step({ kind: "op_result", idempotency_key: `turn:${MUX_SESSION}:2` }, ["persist"]);
    const ready = session("s_c", "fixer", "ready", { lastSeq: 6, turnCount: 1, stateSeq: 4, preview: "fixed" });
    c.step({ kind: "session_changed", session: ready }, ["fetch_child_events"], (e) =>
      c.check(c.get(e, "fetch_child_events").after === 0, "events after the previous turn's floor"),
    );
    const events = [
      ev(1, "user_message", { promptId: "p" }, "mux", "s_c"),
      ev(2, "turn_started", {}, "mux", "s_c"),
      chunk(3, "  fixed it: null check in parser.ts ", "s_c"),
      ev(4, "turn_end", {}, "mux", "s_c"),
    ];
    c.step({ kind: "child_events", session_id: "s_c", events }, ["persist", "prompt", "conversation_op"], (e) => {
      const prompt = c.get(e, "prompt");
      c.check(prompt.prompt_id === "child:s_c:1", "child prompt id uses turnCount");
      c.check(prompt.text.startsWith("[mux-event] child fixer finished: fixed it: null check in parser.ts\n(claude, /work;"), "event text");
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "work:s_c:1" && op.op.kind === "message.edit" && op.op.message_id === "m_card", "card edit");
      c.check(op.op.kind === "message.edit" && op.op.parts[0].type === "work" && op.op.parts[0].status === "done", "card done");
    });
    c.step({ kind: "op_result", idempotency_key: "work:s_c:1" }, ["persist"]);
    c.step({ kind: "session_changed", session: { ...ready, status: "running", turnCount: 1, lastSeq: 7 } }, ["persist", "conversation_op"], (e) =>
      c.check(opKey(c, e) === "work:s_c:2", "running again"),
    );
    c.step({ kind: "op_result", idempotency_key: "work:s_c:2" }, ["persist"]);
    c.step({ kind: "session_changed", session: { ...ready, status: "idle", turnCount: 2, lastSeq: 12 } }, ["fetch_child_events"], (e) =>
      c.check(c.get(e, "fetch_child_events").after === 6, "the floor is the previous turn's lastSeq"),
    );
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a permission from a session not known yet fetches the session list; a known child's is handled at once");
    boot(c);
    const request = {
      toolCall: { title: "Write /tmp/x", rawInput: { path: "/tmp/x", content: "hi" } },
      options: [
        { optionId: "allow-once", name: "Allow", kind: "allow_once" },
        { optionId: "reject-once", kind: "reject_once" },
      ],
    };
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "perm-1", request }, ["fetch_sessions"]);
    const writer = session("s_w", "writer", "waiting", { lastPrompt: "write file" });
    c.step({ kind: "sessions", sessions: [session("s_other", "other", "idle", { tags: {} }), writer] }, ["persist", "conversation_op", "prompt"], (e) => {
      const prompt = c.get(e, "prompt");
      c.check(prompt.prompt_id === "perm:s_w:perm-1", "permission prompt id");
      c.check(
        prompt.text ===
          '[mux-event] child writer asks permission: Write /tmp/x\nInput: {"content":"hi","path":"/tmp/x"}\nOptions: allow-once (Allow), reject-once (reject_once)\nAnswer with `mux agents allow writer OPTION_ID` or `mux agents deny writer`. Ask the user first if it is destructive or outward-facing.',
        "permission text: rawInput as canonical JSON (sorted keys)",
      );
      const state = c.persisted(e);
      c.check(
        state.children.s_w.status === "waiting" && state.outbox.length === 1 && state.children.s_w.edits === 0,
        "a first-seen waiting child: one waiting card, no duplicate waiting edit",
      );
    });
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "perm-2", request: {} }, ["fetch_sessions"]);
    c.step({ kind: "sessions", sessions: [] }, []);
    c.step({ kind: "session_changed", session: writer }, []);
    c.step({ kind: "permission_pending", session_id: "s_w", permission_id: "perm-3", request: {} }, ["persist", "prompt"], (e) =>
      c.check(c.get(e, "prompt").text.includes("asks permission: a tool call\nOptions: (none)"), "empty request"),
    );
    c.step({ kind: "permission_pending", session_id: MUX_SESSION, permission_id: "perm-4", request: {} }, ["fetch_sessions"]);
    c.step({ kind: "sessions", sessions: [session(MUX_SESSION, "mux", "running", { tags: {} })] }, []);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: on reconnect a lost child is marked failed and one that finished meanwhile is finished", {
      defaultConversation: "conv_a",
      muxSessionId: MUX_SESSION,
      children: {
        s_lost: { conversation: "conv_a", name: "lost", status: "running", messageId: "m_l", edits: 0 },
        s_done: { conversation: "conv_a", name: "done", status: "running", messageId: "m_d", edits: 2 },
        s_old: { conversation: "conv_a", name: "old", status: "done", messageId: "m_o", edits: 1 },
      },
    });
    c.step({ kind: "daemon_connected", conversation: summary("conv_a") }, []);
    const done = session("s_done", "done", "ready", { lastSeq: 9, turnCount: 3, preview: "all good" });
    c.step({ kind: "acpmux_connected", session_id: MUX_SESSION, sessions: [done], events: [] }, ["persist", "fetch_child_events", "conversation_op", "list_conversations"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "work:s_lost:1" && op.op.kind === "message.edit" && op.op.message_id === "m_l", "lost child edit");
      c.check(op.op.kind === "message.edit" && op.op.parts[0].type === "work" && op.op.parts[0].status === "failed" && op.op.parts[0].preview === undefined, "failed, no preview");
    });
    c.step({ kind: "child_events", session_id: "s_done", events: [] }, ["persist", "prompt"], (e) => {
      c.check(c.get(e, "prompt").text.includes("finished: (no reply text)"), "no reply text");
      const edit = c.persisted(e).outbox.at(-1)!;
      c.check(edit.idempotency_key === "work:s_done:3" && edit.op.kind === "message.edit" && edit.op.parts[0].type === "work" && edit.op.parts[0].preview === "all good", "the session preview");
    });
    c.step({ kind: "op_result", idempotency_key: "work:s_lost:1" }, ["persist", "conversation_op"]);
    cases.push(c.end());
  }

  {
    const c = new CaseBuilder("children: a running child that closes is marked failed; acpmux loss finishes a child whose events were being fetched");
    boot(c);
    c.step({ kind: "session_changed", session: session("s_x", "x", "running", { preview: "working" }) }, ["persist", "conversation_op"]);
    const cardX = msg("conv_a", 1, AGENT_MUX, "", { id: "m_x", client_msg_id: "work:s_x", parts: [{ type: "work", session: "x", status: "running" }] });
    c.step({ kind: "op_result", idempotency_key: "work:s_x", change: { kind: "message", message: cardX } }, ["persist"]);
    c.step({ kind: "session_changed", session: session("s_x", "x", "closed", { preview: "working" }) }, ["persist", "conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.op.kind === "message.edit" && op.op.parts[0].type === "work" && op.op.parts[0].status === "failed", "failed");
    });
    c.step({ kind: "op_result", idempotency_key: "work:s_x:1" }, ["persist"]);
    c.step({ kind: "session_changed", session: session("s_y", "y", "running") }, ["persist", "conversation_op"]);
    const cardY = msg("conv_a", 2, AGENT_MUX, "", { id: "m_y", client_msg_id: "work:s_y", parts: [{ type: "work", session: "y", status: "running" }] });
    c.step({ kind: "op_result", idempotency_key: "work:s_y", change: { kind: "message", message: cardY } }, ["persist"]);
    c.step({ kind: "session_changed", session: session("s_y", "y", "ready", { turnCount: 1 }) }, ["fetch_child_events"]);
    c.step({ kind: "disconnected", port: "acpmux" }, ["persist", "conversation_op"], (e) => {
      const op = c.get(e, "conversation_op");
      c.check(op.idempotency_key === "work:s_y:1" && op.op.kind === "message.edit" && op.op.message_id === "m_y", "card done");
      c.check(c.persisted(e).prompts["child:s_y:1"] !== undefined, "prompt stays outstanding for the next connect");
    });
    c.step({ kind: "child_events", session_id: "s_y", events: [] }, []);
    cases.push(c.end());
  }

  return cases;
}

// MARK: memory

function memoryCases(): Promise<MemoryCase[]> {
  const specs: [string, MemoryFunction, Record<string, unknown>][] = [
    ["to_lines flattens whitespace", "to_lines", { text: " a \n\t b " }],
    ["to_lines of blank text is empty", "to_lines", { text: " \n\t " }],
    ["to_lines of empty text is empty", "to_lines", { text: "" }],
    ["to_lines uses the JavaScript whitespace set (NBSP, EM SPACE, BOM yes; NEL no)", "to_lines", { text: "a b c﻿d\u0085e" }],
    ["to_lines cuts long text on a word boundary with an ellipsis", "to_lines", { text: "word ".repeat(100) }],
    ["to_lines cuts text with no spaces at the byte limit", "to_lines", { text: "x".repeat(600) }],
    ["to_lines counts UTF-8 bytes of two-byte text", "to_lines", { text: "é".repeat(300) }],
    ["to_lines counts UTF-8 bytes of three-byte text with spaces", "to_lines", { text: "漢字かな ".repeat(40) }],
    ["to_lines keeps four-byte characters whole", "to_lines", { text: "😀".repeat(100) }],
    ["to_lines never cuts a surrogate pair in mixed text", "to_lines", { text: `é${"😀".repeat(100)}` }],
    ["to_lines prefers a space only past half the line", "to_lines", { text: `${"a".repeat(100)} ${"b".repeat(400)}` }],
    ["decompose 0", "decompose", { length: 0 }],
    ["decompose 1", "decompose", { length: 1 }],
    ["decompose 11", "decompose", { length: 11 }],
    ["decompose 13", "decompose", { length: 13 }],
    ["decompose 1000", "decompose", { length: 1000 }],
    ["wake cover 8 within 1", "wake_cover", { length: 8, budget: 1 }],
    ["wake cover 8 within 2", "wake_cover", { length: 8, budget: 2 }],
    ["wake cover splits the newest block", "wake_cover", { length: 8, budget: 4 }],
    ["wake cover of a short log is every line", "wake_cover", { length: 3, budget: 96 }],
    ["wake cover 1000 within 20", "wake_cover", { length: 1000, budget: 20 }],
    ["wake of an empty log", "wake", { lines: [], budget: 96 }],
    ["wake shows children of a missing summary", "wake", { lines: ["a", "b", "c", "d"], budget: 1 }],
    ["wake shows a summary", "wake", { lines: ["a", "b", "c", "d"], nodes: { "0-3": "abcd" }, budget: 1 }],
    [
      "wake mixes summaries, partial summaries and lines",
      "wake",
      { lines: ["l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10"], nodes: { "0-3": "first four", "6-7": "six seven" }, budget: 4 },
    ],
    ["zoom mixes a child summary and numbered lines", "zoom", { lines: ["a", "b", "c", "d"], nodes: { "0-1": "ab" }, range: "0-3" }],
    ["zoom shows both child summaries", "zoom", { lines: ["a", "b", "c", "d", "e", "f", "g", "h"], nodes: { "0-3": "abcd", "4-7": "efgh" }, range: "0-7" }],
    ["zoom of two lines is the raw lines", "zoom", { lines: ["a", "b", "c", "d"], range: "2-3" }],
    ["zoom of an unaligned range is the raw lines", "zoom", { lines: ["a", "b", "c", "d", "e"], range: "1-4" }],
    ["wake treats an empty summary as missing", "wake", { lines: ["a", "b", "c", "d"], nodes: { "0-3": "" }, budget: 1 }],
    ["zoom treats an empty child summary as missing", "zoom", { lines: ["a", "b", "c", "d", "e", "f", "g", "h"], nodes: { "0-3": "", "4-7": "efgh" }, range: "0-7" }],
  ];
  return Promise.all(
    specs.map(async ([name, fn, args]) => {
      const result = plain(await memoryResult(fn, args));
      // JSON.stringify escapes a lone surrogate (and only a lone one) as \udXXX.
      if (/\\ud[89a-f][0-9a-f]{2}/i.test(JSON.stringify(result)))
        throw new Error(`${name}: result has a lone surrogate; the Rust core cannot hold it`);
      return { name, fn, args, result };
    }),
  );
}

/** Intent checks on memory results (the generator fails when one does not hold). */
function checkMemory(cases: MemoryCase[]): void {
  const by = (name: string) => cases.find((c) => c.name === name)!.result;
  const expect = (name: string, want: unknown) => {
    if (JSON.stringify(by(name)) !== JSON.stringify(want)) throw new Error(`${name}: got ${JSON.stringify(by(name))}`);
  };
  expect("to_lines flattens whitespace", ["a b"]);
  expect("to_lines of blank text is empty", []);
  expect("to_lines uses the JavaScript whitespace set (NBSP, EM SPACE, BOM yes; NEL no)", ["a b c d\u0085e"]);
  expect("decompose 11", ["0-7", "8-9", "10-10"]);
  expect("decompose 0", []);
  expect("wake cover splits the newest block", ["0-3", "4-5", "6-6", "7-7"]);
  expect("wake shows a summary", { text: "#0-3 abcd", missing: [] });
  expect("zoom mixes a child summary and numbered lines", ["#0-1 ab", "#2 c", "#3 d"]);
  expect("zoom of an unaligned range is the raw lines", ["b", "c", "d", "e"]);
  expect("wake treats an empty summary as missing", { text: "#0 a\n#1 b\n#2 c\n#3 d", missing: ["0-3"] });
  expect("zoom treats an empty child summary as missing", ["#0 a", "#1 b", "#2 c", "#3 d", "#4-7 efgh"]);
  const encoder = new TextEncoder();
  for (const c of cases.filter((x) => x.fn === "to_lines")) {
    const lines = c.result as string[];
    for (const line of lines) if (encoder.encode(line).length > 280) throw new Error(`${c.name}: line over 280 bytes`);
    for (const line of lines.slice(0, -1)) if (!line.endsWith("…")) throw new Error(`${c.name}: cut line without the mark`);
  }
  const words = by("to_lines cuts long text on a word boundary with an ellipsis") as string[];
  if (words.length < 2 || !words[0].endsWith("word…")) throw new Error("word boundary");
}

export const NOTES = [
  "Generated by mux/packages/brain/conformance/generate.ts from the TypeScript core (packages/brain/src/core); do not edit by hand.",
  "A case: {name, state, steps [{now, input, effects}], state_after}. Start a core from `state` (host.json shape, camelCase), feed each input at `now` (ms since the epoch), and compare the effects as JSON values in order; `log` effects are not compared; object key order does not matter; optional fields are omitted when absent.",
  "Inputs and effects are tagged by snake_case `kind`. `persist` carries the whole durable state and is the first effect of every step that changed it (write-ahead).",
  "A memory case: {name, fn, args, result}; fn is to_lines, decompose, wake_cover, wake or zoom; ranges are `lo-hi`; wake returns {text, missing}.",
  "JSON text inside prompts and replies (a turn_error without an `error` field, a permission's rawInput) is canonical: compact, object keys sorted by code point (serde_json Value::to_string). A non-string turn_error `error` is JavaScript String(value): [object Object] for an object, items joined by commas for an array.",
  "Text rules: trim and to_lines whitespace is the JavaScript set (\\s, String.prototype.trim); cuts count UTF-16 units and never split a surrogate pair; an empty promptId is no prompt id; an empty memory summary counts as missing; only string fields of a permission request count.",
  "A connected input while that port is up counts as a disconnect first. A child's session_changed inputs wait behind its pending finish (fetch_child_events) and are replayed in order.",
];

export async function buildCorpus(): Promise<Corpus> {
  const cases = [...wakeCases(), ...catchUpCases(), ...disconnectCases(), ...turnCases(), ...outboxCases(), ...childCases()];
  const names = new Set<string>();
  for (const c of cases) {
    if (names.has(c.name)) throw new Error(`duplicate case ${c.name}`);
    names.add(c.name);
  }
  const memory = await memoryCases();
  checkMemory(memory);
  return { format: CORPUS_FORMAT, notes: NOTES, cases, memory };
}
