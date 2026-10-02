import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { answerPermission, listAgents, spawnAgent } from "../src/agents.ts";
import { AGENT_MUX, type Message, messageText, USER_LOCAL } from "../src/conversation-types.ts";
import { DaemonClient, DaemonError, MissingCapabilityError } from "../src/daemon-client.ts";
import { HostAlreadyRunningError } from "../src/host.ts";
import { deferred, world } from "./helpers.ts";

let cleanup: (() => Promise<void>) | undefined;
afterEach(async () => {
  await cleanup?.();
  cleanup = undefined;
});

async function setup() {
  const w = await world();
  cleanup = w.close;
  return w;
}

const muxReplies = (messages: Message[]) => messages.filter((m) => m.author === AGENT_MUX && m.parts[0]?.type === "text");

describe("daemon client vs the fake daemon", () => {
  test("refuses a daemon without local-conversations-v1", async () => {
    const w = await setup();
    w.daemon.capabilities = ["something-else"];
    await expect(DaemonClient.connect(w.daemon.path)).rejects.toBeInstanceOf(MissingCapabilityError);
  });

  test("create is idempotent, ops replay, rejects carry the reason, events stream after subscribe", async () => {
    const w = await setup();
    const events: Record<string, unknown>[] = [];
    const client = await DaemonClient.connect(w.daemon.path, { subscribe: true, onEvent: (e) => events.push(e) });
    expect(w.daemon.requests.map((r) => r.cmd)).toEqual(["identify", "subscribe"]);
    expect(w.daemon.requests[1].tree_events).toBe("deltas");
    const params = {
      idempotency_key: "k",
      actor: USER_LOCAL,
      title: "t",
      participants: [{ id: USER_LOCAL, kind: "human" as const, display_name: "U" }],
    };
    const first = await client.create(params);
    const again = await client.create(params);
    expect(again.replayed).toBe(true);
    expect(again.conversation.id).toBe(first.conversation.id);
    const op = { conversation: first.conversation.id, idempotency_key: "m1", actor: USER_LOCAL, op: { kind: "message.send" as const, client_msg_id: "m1", parts: [{ type: "text" as const, text: "hi" }] } };
    const sent = await client.op(op);
    expect(sent.replayed).toBe(false);
    expect((await client.op(op)).replayed).toBe(true);
    const rejected = await client.op({ ...op, idempotency_key: "m2", actor: "agent_nobody", op: { ...op.op, client_msg_id: "m2" } }).catch((e) => e);
    expect(rejected).toBeInstanceOf(DaemonError);
    expect((rejected as DaemonError).code).toBe("conversation_rejected");
    expect((rejected as DaemonError).message).toContain("not_participant");
    const snapshot = await client.snapshot(first.conversation.id, 10);
    expect(snapshot.messages.map(messageText)).toEqual(["hi"]);
    await w.daemon.until(() => events.length >= 1);
    expect(events[0].event).toBe("conversation-changed");
    client.close();
  });
});

describe("inbox", () => {
  test("a human message prompts the mux with promptId = message id; the reply is posted by agent_mux with the turn key", async () => {
    const w = await setup();
    const host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    const summary = w.daemon.conversation(conv).summary;
    expect(summary.title).toBe("mux");
    expect(summary.participants).toEqual([
      { id: USER_LOCAL, kind: "human", display_name: "Test User" },
      { id: AGENT_MUX, kind: "agent", display_name: "mux", agent_class: "mux", acp_session: "mux" },
    ]);
    const mux = w.acpmux.byName("mux")!;
    expect(mux.summary.harness).toBe("claude-sr");
    expect(mux.summary.cwd).toBe(join(w.home, "session"));
    expect(existsSync(join(w.home, "session", "CLAUDE.md"))).toBe(true);
    const settings = JSON.parse(readFileSync(join(w.home, "session", ".claude", "settings.json"), "utf8"));
    expect(settings.hooks.UserPromptSubmit[0].hooks[0].command).toContain("hook user-prompt-submit");

    const message = w.daemon.send(conv, USER_LOCAL, "hello mux");
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    expect(w.acpmux.userMessages("mux")).toEqual([
      { text: `[conversation ${conv} from Test User] hello mux`, promptId: message.id },
    ]);
    const reply = muxReplies(w.daemon.messages(conv))[0];
    expect(messageText(reply)).toBe(`echo: [conversation ${conv} from Test User] hello mux`);
    const turnStarted = mux.events.find((e) => e.kind === "turn_started")!;
    expect(reply.client_msg_id).toBe(`turn:${mux.summary.sessionId}:${turnStarted.seq}`);
    const send = w.daemon.requests.find((r) => r.cmd === "conversation-op" && (r.op as { kind: string }).kind === "message.send")!;
    expect(send.actor).toBe(AGENT_MUX);
    expect(send.idempotency_key).toBe(reply.client_msg_id);
    await w.daemon.until(() => w.daemon.typing.length >= 2);
    expect(w.daemon.typing).toEqual([
      { conversation: conv, actor: AGENT_MUX, on: true },
      { conversation: conv, actor: AGENT_MUX, on: false },
    ]);
    // agent_mux has read the human message and its own reply.
    expect(w.daemon.conversation(conv).summary.read_cursors[AGENT_MUX]).toBeGreaterThanOrEqual(message.seq);
    // The prompt carried delivery "turn" and the session was created approve-all with no MCP server.
    const prompt = w.acpmux.calls.find((c) => c.method === "session/prompt")!;
    expect(prompt.params._meta).toEqual({ acpmux: { promptId: message.id, delivery: "turn" } });
    const created = w.acpmux.calls.find((c) => c.method === "session/new")!;
    expect(created.params._meta).toEqual({ acpmux: { name: "mux", harness: "claude-sr", policy: "approve-all" } });
  });

  test("restart catches up from the read cursor: a message sent while down is answered once, older ones never again", async () => {
    const w = await setup();
    let host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    w.daemon.send(conv, USER_LOCAL, "one");
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    await host.stop();

    w.daemon.send(conv, USER_LOCAL, "two");
    host = w.host();
    host.start();
    await host.ready;
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 2);
    // A third restart with nothing new changes nothing.
    await host.stop();
    host = w.host();
    host.start();
    await host.ready;
    w.daemon.send(conv, USER_LOCAL, "three");
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 3);
    expect(w.acpmux.userMessages("mux").map((m) => m.text.split("] ")[1])).toEqual(["one", "two", "three"]);
    expect(muxReplies(w.daemon.messages(conv)).map(messageText).map((t) => t.split("] ")[1])).toEqual(["one", "two", "three"]);
  });

  test("a host stopped mid-turn posts that turn's reply exactly once after restart", async () => {
    const w = await setup();
    const hold = deferred<string>();
    w.acpmux.respond = () => hold.promise;
    let host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    const message = w.daemon.send(conv, USER_LOCAL, "slow one");
    await w.acpmux.until(() => w.acpmux.userMessages("mux").length === 1);
    await host.stop();
    hold.resolve("done slowly");
    await w.acpmux.until(() => w.acpmux.byName("mux")!.summary.status === "ready");

    host = w.host();
    host.start();
    await host.ready;
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    // Settle: the restart also resent the outstanding prompt; acpmux deduped it by promptId.
    await w.daemon.until(() => w.daemon.typing.some((t) => !t.on));
    expect(w.acpmux.userMessages("mux")).toEqual([{ text: `[conversation ${conv} from Test User] slow one`, promptId: message.id }]);
    expect(muxReplies(w.daemon.messages(conv)).map(messageText)).toEqual(["done slowly"]);
    const state = JSON.parse(readFileSync(join(w.home, "state", "host.json"), "utf8"));
    expect(state.prompts).toEqual({});
  });

  test("daemon restart: the host resubscribes and answers what arrived meanwhile", async () => {
    const w = await setup();
    const host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    w.daemon.dropClients();
    w.daemon.send(conv, USER_LOCAL, "while away");
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    expect(w.acpmux.userMessages("mux").length).toBe(1);
  });
});

describe("wake rules", () => {
  test("two humans: only a mention or a reply to the mux wakes it", async () => {
    const w = await setup();
    const host = w.host();
    host.start();
    await host.ready;
    const conv = w.daemon.createConversation("group", [
      { id: USER_LOCAL, kind: "human", display_name: "Test User" },
      { id: "user_ana", kind: "human", display_name: "Ana" },
      { id: AGENT_MUX, kind: "agent", display_name: "mux", agent_class: "mux", acp_session: "mux" },
    ]);
    const plain = w.daemon.send(conv, "user_ana", "just chatting");
    const mention = w.daemon.send(conv, "user_ana", "hey @mux status?", { runs: [{ start: 4, length: 4, mention: AGENT_MUX }] });
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    const muxMessage = muxReplies(w.daemon.messages(conv))[0];
    w.daemon.send(conv, USER_LOCAL, "thanks", { reply_to: { message_id: muxMessage.id, part_index: 0 } });
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 2);
    const prompts = w.acpmux.userMessages("mux");
    expect(prompts.map((p) => p.promptId)).not.toContain(plain.id);
    expect(prompts[0]).toEqual({ text: `[conversation ${conv} from Ana] hey @mux status?`, promptId: mention.id });
    expect(prompts[1].text).toBe(`[conversation ${conv} from Test User] thanks`);
    // The cursor still moves past the message that did not wake the mux.
    expect(w.daemon.conversation(conv).summary.read_cursors[AGENT_MUX]).toBeGreaterThan(plain.seq);
  });

  test("a conversation without the mux is ignored", async () => {
    const w = await setup();
    const host = w.host();
    host.start();
    await host.ready;
    const conv = w.daemon.createConversation("humans", [{ id: USER_LOCAL, kind: "human", display_name: "Test User" }]);
    w.daemon.send(conv, USER_LOCAL, "note to self");
    const [muxConv] = w.daemon.conversationIds;
    w.daemon.send(muxConv, USER_LOCAL, "ping");
    await w.daemon.until(() => muxReplies(w.daemon.messages(muxConv)).length === 1);
    expect(w.acpmux.userMessages("mux").map((m) => m.text)).toEqual([`[conversation ${muxConv} from Test User] ping`]);
  });
});

describe("children", () => {
  test("a spawned child gets a work card; its turn end prompts the mux with [mux-event] and marks the card done", async () => {
    const w = await setup();
    const childHold = deferred<string>();
    const muxTurn = deferred<string>();
    w.acpmux.respond = (session, text) => {
      if (session.name === "fixer") return childHold.promise;
      if (text.includes("spawn please")) return muxTurn.promise;
      return `ok: ${text.slice(0, 40)}`;
    };
    const host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    w.daemon.send(conv, USER_LOCAL, "spawn please");
    await w.acpmux.until(() => w.acpmux.byName("mux")!.summary.status === "running");
    // The mux runs `mux agents spawn` from its shell during its turn.
    const child = await spawnAgent(w.acpmux.path, { cwd: w.dir, name: "fixer", harness: "claude", prompt: "fix the bug" });
    expect(child.tags["mux.parent"]).toBe("mux");
    expect((await listAgents(w.acpmux.path)).map((s) => s.name)).toEqual(["fixer"]);
    await w.daemon.until(() => w.daemon.messages(conv).some((m) => m.parts[0]?.type === "work"));
    muxTurn.resolve("started fixer");
    const card = () => w.daemon.messages(conv).find((m) => m.parts[0]?.type === "work")!;
    expect(card().author).toBe(AGENT_MUX);
    expect(card().parts[0]).toMatchObject({ type: "work", session: "fixer", status: "running" });

    childHold.resolve("fixed it: null check in parser.ts");
    await w.acpmux.until(() => w.acpmux.userMessages("mux").some((m) => m.text.startsWith("[mux-event] child fixer finished")));
    const event = w.acpmux.userMessages("mux").find((m) => m.text.startsWith("[mux-event]"))!;
    expect(event.text).toContain("fixed it: null check in parser.ts");
    expect(event.promptId).toStartWith(`child:${child.sessionId}:`);
    await w.daemon.until(() => card().parts[0]?.type === "work" && (card().parts[0] as { status: string }).status === "done");
    // The mux's reply to the event lands in the conversation the child was started from.
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).some((m) => messageText(m).startsWith("ok: [mux-event]")));
  });

  test("a child permission request reaches the mux with option ids and is answered through `mux agents allow`", async () => {
    const w = await setup();
    const childHold = deferred<string>();
    w.acpmux.respond = (session, text) => (session.name === "writer" ? childHold.promise : `ok: ${text.slice(0, 30)}`);
    const host = w.host();
    host.start();
    await host.ready;
    const child = await spawnAgent(w.acpmux.path, { cwd: w.dir, name: "writer", prompt: "write file" });
    w.acpmux.requestPermission(child.sessionId, {
      toolCall: { title: "Write /tmp/x" },
      options: [
        { optionId: "allow-once", name: "Allow", kind: "allow_once" },
        { optionId: "reject-once", name: "Reject", kind: "reject_once" },
      ],
    });
    await w.acpmux.until(() => w.acpmux.userMessages("mux").some((m) => m.text.includes("asks permission")));
    const event = w.acpmux.userMessages("mux").find((m) => m.text.includes("asks permission"))!;
    expect(event.text).toContain("allow-once (Allow)");
    expect(event.promptId).toBe(`perm:${child.sessionId}:perm-1`);
    expect(await answerPermission(w.acpmux.path, "writer", { allow: true })).toBe("allow-once");
    childHold.resolve("wrote it");
    await w.acpmux.until(() => w.acpmux.userMessages("mux").some((m) => m.text.includes("child writer finished")));
  });
});

describe("lifecycle", () => {
  test("one host per MUX_HOME", async () => {
    const w = await setup();
    w.host().start();
    expect(() => w.host().start()).toThrow(HostAlreadyRunningError);
  });

  test("a daemon without local-conversations-v1 stops the host", async () => {
    const w = await setup();
    w.daemon.capabilities = [];
    const host = w.host();
    host.start();
    await expect(host.fatal).rejects.toBeInstanceOf(MissingCapabilityError);
  });
});

describe("owner-stamped principal", () => {
  test("the host binds as agent_mux with the app's token right after creating the conversation", async () => {
    const w = await setup();
    w.host({ agentToken: "secret-token" }).start();
    for (let i = 0; i < 200 && w.daemon.bindings.length === 0; i++) await Bun.sleep(5);
    expect(w.daemon.bindings).toEqual([{ participant: AGENT_MUX, token: "secret-token" }]);
    const cmds = w.daemon.requests.map((r) => r.cmd);
    expect(cmds.indexOf("conversation-bind")).toBeGreaterThan(cmds.indexOf("conversation-create"));
  });
});

describe("owner turn budget", () => {
  test("an agent_rate reject is retried once after the gap; agent_budget is dropped", async () => {
    const w = await setup();
    const host = w.host();
    host.start();
    await host.ready;
    const [conv] = w.daemon.conversationIds;
    w.daemon.rejectAgentSends = 1;
    w.daemon.send(conv, USER_LOCAL, "first");
    await w.daemon.until(() => muxReplies(w.daemon.messages(conv)).length === 1);
    expect(w.lines.some((line) => line.includes("retrying once after it"))).toBe(true);

    w.daemon.rejectAgentSends = 1;
    w.daemon.agentReject = "agent_budget";
    w.daemon.send(conv, USER_LOCAL, "second");
    await w.daemon.until(() => w.lines.some((line) => line.includes("dropping rejected op")));
    expect(muxReplies(w.daemon.messages(conv)).length).toBe(1);
  }, 15000);
});
