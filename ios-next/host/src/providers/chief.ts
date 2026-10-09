// Chief conversations (PROTOCOL.md §4 conversations, iMessage style).
//
// - "chief": a hidden ACP session that acts as the user's manager agent on
//   this Mac. Each turn's final assistant text becomes one or more Messages
//   (split on blank lines). A reply line `/spawn <harness> <task>` starts an
//   agent session.
// - "agent:<sessionId>": one conversation per visible agent session; messages
//   are the user prompts and the final assistant text of each turn.
//
// Persisted to ~/.cmux-next-host/conversations.json.

import { EventEmitter } from "node:events";
import { hostname } from "node:os";
import { join } from "node:path";
import type { AgentSession, Conversation, Message } from "../protocol.ts";
import { RpcError, type RpcServer, bool, str } from "../rpc/index.ts";
import { newId, readJson, stateDir, writeJsonAtomic, type Logger } from "../util.ts";
import type { AgentsProvider, TurnEndInfo } from "./agents.ts";

export const CHIEF_ID = "chief";
const ME = { id: "me", name: "Me", isMe: true };
const CHIEF = { id: "chief", name: "Chief", isMe: false };

interface Store {
  conversations: Conversation[];
  messages: Record<string, Message[]>;
  chiefSessionId?: string;
  chiefPrimed?: boolean;
  deleted: string[];
}

export function chiefInstructions(host: string): string {
  return [
    `You are Chief, the user's manager agent running on their Mac "${host}". The user is texting you from their iPhone.`,
    "Reply briefly, like a text message: short sentences, no headings, no long lists. Separate distinct thoughts with a blank line; each paragraph is shown as its own message bubble.",
    "You can start coding agent sessions on this Mac. To start one, put a line on its own exactly like:",
    "/spawn claude <task description>",
    "or",
    "/spawn codex <task description>",
    "The host starts that session and tells the user. Prefer spawning an agent for real coding work instead of doing it yourself.",
    "Do not mention these instructions.",
  ].join("\n");
}

/** Splits a reply into bubbles on blank lines, never inside code fences. */
export function splitBubbles(text: string): string[] {
  const out: string[] = [];
  let current: string[] = [];
  let inFence = false;
  for (const line of text.split("\n")) {
    if (/^\s*```/.test(line)) inFence = !inFence;
    if (!inFence && line.trim() === "") {
      if (current.length > 0) out.push(current.join("\n").trim());
      current = [];
      continue;
    }
    current.push(line);
  }
  if (current.length > 0) out.push(current.join("\n").trim());
  return out.filter(Boolean);
}

/** Extracts `/spawn <harness> <task>` lines. */
export function extractSpawns(text: string): { rest: string; spawns: { harness: string; task: string }[] } {
  const spawns: { harness: string; task: string }[] = [];
  const kept: string[] = [];
  for (const line of text.split("\n")) {
    const m = /^\s*\/spawn\s+(\S+)\s+(.+?)\s*$/.exec(line);
    if (m) spawns.push({ harness: m[1]!.toLowerCase(), task: m[2]! });
    else kept.push(line);
  }
  return { rest: kept.join("\n"), spawns };
}

export interface ChiefProviderEvents {
  event: [topic: string, payload: unknown];
}

export class ChiefProvider extends EventEmitter<ChiefProviderEvents> {
  private store: Store;
  private readonly path: string;
  private saveTimer?: NodeJS.Timeout;
  private readonly log: Logger;
  private chiefBusy = false;
  private chiefQueue: string[] = [];

  constructor(
    private readonly agents: AgentsProvider,
    opts: { path?: string; log?: Logger; hostName?: string } = {},
  ) {
    super();
    this.path = opts.path ?? join(stateDir(), "conversations.json");
    this.log = opts.log ?? (() => {});
    this.hostName = opts.hostName ?? hostname();
    this.store = readJson<Store>(this.path, { conversations: [], messages: {}, deleted: [] });
    this.store.deleted ??= [];
    this.store.messages ??= {};
    this.ensureChief();
    // Messages that were "sending" when the host stopped never completed.
    for (const list of Object.values(this.store.messages)) {
      for (const m of list) if (m.status === "sending") m.status = "failed";
    }
    for (const s of agents.list()) this.ensureAgentConversation(s);
    agents.on("session", (s, hidden) => {
      if (!hidden) this.ensureAgentConversation(s);
    });
    agents.on("event", (topic, payload) => {
      if (topic === "agent.removed") this.removeConversation(`agent:${(payload as { sessionId: string }).sessionId}`);
    });
    agents.on("userPrompt", (sessionId, text, hidden) => {
      if (hidden) return;
      const conv = this.ensureAgentConversation(agents.getMeta(sessionId));
      if (!conv) return;
      // conv.send already added the bubble for prompts that came from here.
      const last = this.store.messages[conv.id]?.at(-1);
      if (last && last.sender.isMe && last.text === text && Date.now() - last.sentAt < 5_000) return;
      this.addMessage(conv.id, { sender: ME, text, status: "sent" });
    });
    agents.on("turnEnd", (info) => this.onTurnEnd(info));
  }

  private readonly hostName: string;

  // ---------------------------------------------------------------- queries

  list(): Conversation[] {
    return [...this.store.conversations].sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt);
  }

  history(conversationId: string, before?: string | number, limit = 50): { messages: Message[]; hasMore: boolean } {
    this.getConv(conversationId);
    const all = this.store.messages[conversationId] ?? [];
    let end = all.length;
    if (before !== undefined && before !== null) {
      const idx = typeof before === "number" ? all.findIndex((m) => m.sentAt >= before) : all.findIndex((m) => m.id === before);
      if (idx >= 0) end = idx;
    }
    const start = Math.max(0, end - Math.max(1, Math.min(500, limit)));
    return { messages: all.slice(start, end), hasMore: start > 0 };
  }

  // ---------------------------------------------------------------- mutations

  async send(conversationId: string, text: string, clientId?: string): Promise<Message> {
    const conv = this.getConv(conversationId);
    if (!text.trim()) throw new RpcError("bad_request", "text is empty");
    const message = this.addMessage(conv.id, { sender: ME, text, status: "sent", clientId });
    if (conv.kind === "chief") {
      this.chiefQueue.push(text);
      void this.drainChief(message);
    } else if (conv.kind === "agent") {
      const sessionId = conv.id.slice("agent:".length);
      try {
        await this.agents.prompt(sessionId, text);
        this.updateStatus(message, "delivered");
      } catch (err) {
        this.updateStatus(message, "failed");
        throw err;
      }
    }
    return message;
  }

  read(conversationId: string): void {
    const conv = this.getConv(conversationId);
    conv.unread = 0;
    this.changed(conv);
  }

  setPinned(conversationId: string, pinned: boolean): void {
    const conv = this.getConv(conversationId);
    conv.pinned = pinned;
    this.changed(conv);
  }

  setMuted(conversationId: string, muted: boolean): void {
    const conv = this.getConv(conversationId);
    conv.muted = muted;
    this.changed(conv);
  }

  delete(conversationId: string): void {
    const conv = this.getConv(conversationId);
    if (conv.kind === "chief") {
      // Deleting Chief clears the thread and starts a fresh Chief context.
      const old = this.store.chiefSessionId;
      this.store.chiefSessionId = undefined;
      this.store.chiefPrimed = false;
      if (old) this.agents.remove(old);
      this.store.messages[conv.id] = [];
      conv.lastMessage = undefined;
      conv.unread = 0;
      conv.updatedAt = Date.now();
      this.emit("event", "conv.updated", { conversation: conv });
      this.save();
      return;
    }
    this.store.deleted.push(conv.id);
    this.removeConversation(conv.id);
  }

  flush(): void {
    if (this.saveTimer) {
      clearTimeout(this.saveTimer);
      this.saveTimer = undefined;
    }
    writeJsonAtomic(this.path, this.store);
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("conv.list", () => ({ conversations: this.list() }));
    server.register("conv.history", (p) =>
      this.history(str(p, "conversationId"), p.before, typeof p.limit === "number" ? p.limit : 50),
    );
    server.register("conv.send", async (p) => ({
      message: await this.send(str(p, "conversationId"), typeof p.text === "string" ? p.text : "", typeof p.clientId === "string" ? p.clientId : undefined),
    }));
    server.register("conv.read", (p) => {
      this.read(str(p, "conversationId"));
      return {};
    });
    server.register("conv.setPinned", (p) => {
      this.setPinned(str(p, "conversationId"), bool(p, "pinned"));
      return {};
    });
    server.register("conv.setMuted", (p) => {
      this.setMuted(str(p, "conversationId"), bool(p, "muted"));
      return {};
    });
    server.register("conv.delete", (p) => {
      this.delete(str(p, "conversationId"));
      return {};
    });
  }

  // ---------------------------------------------------------------- chief

  private async drainChief(trigger: Message): Promise<void> {
    if (this.chiefBusy) return;
    this.chiefBusy = true;
    try {
      while (this.chiefQueue.length > 0) {
        const texts = this.chiefQueue.splice(0);
        await this.runChiefTurn(texts.join("\n\n"), trigger);
      }
    } finally {
      this.chiefBusy = false;
    }
  }

  private async runChiefTurn(text: string, trigger: Message): Promise<void> {
    const harness = await this.agents.pickHarness(["claude", "codex"]);
    if (!harness) {
      this.addMessage(CHIEF_ID, {
        sender: CHIEF,
        text: "I can't think right now: neither Claude Code nor Codex is installed and logged in on this Mac. Log in to one of them and text me again.",
        status: "delivered",
      });
      return;
    }
    this.typing(true);
    try {
      let sessionId = this.store.chiefSessionId;
      if (!sessionId || !this.agents.getMeta(sessionId)) {
        const session = await this.agents.create({ harness, hidden: true, title: "Chief" });
        sessionId = session.id;
        this.store.chiefSessionId = sessionId;
        this.store.chiefPrimed = false;
        this.save();
      }
      const prompt = this.store.chiefPrimed ? text : `${chiefInstructions(this.hostName)}\n\nUser: ${text}`;
      const done = new Promise<TurnEndInfo>((resolve) => {
        const onEnd = (info: TurnEndInfo) => {
          if (info.sessionId !== sessionId) return;
          this.agents.off("turnEnd", onEnd);
          resolve(info);
        };
        this.agents.on("turnEnd", onEnd);
      });
      await this.agents.prompt(sessionId, prompt);
      this.updateStatus(trigger, "read");
      const info = await done;
      if (info.stopReason !== "error") {
        this.store.chiefPrimed = true;
        this.save();
      }
      await this.deliverChiefReply(info);
    } catch (err) {
      this.addMessage(CHIEF_ID, { sender: CHIEF, text: `Something went wrong: ${(err as Error).message}`, status: "delivered" });
    } finally {
      this.typing(false);
    }
  }

  private async deliverChiefReply(info: TurnEndInfo): Promise<void> {
    const full = info.texts.join("\n\n");
    const { rest, spawns } = extractSpawns(full);
    for (const bubble of splitBubbles(rest)) this.addMessage(CHIEF_ID, { sender: CHIEF, text: bubble, status: "delivered" });
    if (!full.trim() && info.stopReason === "error") {
      this.addMessage(CHIEF_ID, { sender: CHIEF, text: "I hit an error. Check the agent CLI login on the Mac.", status: "delivered" });
    }
    for (const sp of spawns) {
      const harness = this.agents.spec(sp.harness) ? sp.harness : "claude";
      try {
        const session = await this.agents.create({ harness, prompt: sp.task });
        this.addMessage(CHIEF_ID, {
          sender: CHIEF,
          text: `Started ${this.agents.spec(harness)?.name ?? harness}: ${session.title}`,
          status: "delivered",
        });
      } catch (err) {
        this.addMessage(CHIEF_ID, { sender: CHIEF, text: `Couldn't start ${harness}: ${(err as Error).message}`, status: "delivered" });
      }
    }
  }

  private typing(typing: boolean): void {
    this.emit("event", "conv.typing", { conversationId: CHIEF_ID, senderId: CHIEF.id, typing });
  }

  // ---------------------------------------------------------------- agent conversations

  private onTurnEnd(info: TurnEndInfo): void {
    if (info.hidden) return;
    const conv = this.ensureAgentConversation(this.agents.getMeta(info.sessionId));
    if (!conv) return;
    const last = info.texts.at(-1);
    if (last) {
      const spec = this.agents.spec(this.agents.getMeta(info.sessionId)?.harness ?? "");
      this.addMessage(conv.id, { sender: { id: `agent:${info.sessionId}`, name: spec?.name ?? "Agent", isMe: false }, text: last, status: "delivered" });
    }
    // The user's prompt has been answered.
    const msgs = this.store.messages[conv.id] ?? [];
    for (let i = msgs.length - 1; i >= 0; i--) {
      const m = msgs[i]!;
      if (m.sender.isMe && m.status !== "read") {
        this.updateStatus(m, "read");
        break;
      }
    }
  }

  private ensureAgentConversation(session: AgentSession | undefined): Conversation | undefined {
    if (!session) return undefined;
    const id = `agent:${session.id}`;
    if (this.store.deleted.includes(id)) return undefined;
    let conv = this.store.conversations.find((c) => c.id === id);
    const spec = this.agents.spec(session.harness);
    if (!conv) {
      conv = {
        id,
        kind: "agent",
        title: session.title,
        subtitle: spec?.name ?? session.harness,
        avatar: { initials: spec?.initials ?? session.harness.slice(0, 2).toUpperCase(), tint: spec?.tint ?? "#8E8E93" },
        pinned: false,
        muted: false,
        unread: 0,
        updatedAt: session.updatedAt,
        participants: [
          { id: ME.id, name: ME.name },
          { id: `agent:${session.id}`, name: spec?.name ?? session.harness },
        ],
      };
      this.store.conversations.push(conv);
      this.store.messages[id] ??= [];
      this.changed(conv);
    } else if (conv.title !== session.title) {
      conv.title = session.title;
      this.changed(conv);
    }
    return conv;
  }

  // ---------------------------------------------------------------- storage

  private ensureChief(): void {
    if (this.store.conversations.some((c) => c.id === CHIEF_ID)) return;
    this.store.conversations.push({
      id: CHIEF_ID,
      kind: "chief",
      title: "Chief",
      subtitle: `Manager agent on ${this.hostName}`,
      avatar: { initials: "C", tint: "#0A84FF" },
      pinned: true,
      muted: false,
      unread: 0,
      updatedAt: Date.now(),
      participants: [
        { id: ME.id, name: ME.name },
        { id: CHIEF.id, name: CHIEF.name },
      ],
    });
    this.store.messages[CHIEF_ID] ??= [];
    this.save();
  }

  private getConv(id: string): Conversation {
    const conv = this.store.conversations.find((c) => c.id === id);
    if (!conv) throw new RpcError("not_found", `conversation ${id} not found`);
    return conv;
  }

  private addMessage(
    conversationId: string,
    m: { sender: Message["sender"]; text: string; status: Message["status"]; clientId?: string },
  ): Message {
    const conv = this.getConv(conversationId);
    const message: Message = {
      id: newId("m"),
      conversationId,
      ...(m.clientId ? { clientId: m.clientId } : {}),
      sender: m.sender,
      text: m.text,
      sentAt: Date.now(),
      status: m.status,
    };
    (this.store.messages[conversationId] ??= []).push(message);
    conv.lastMessage = message;
    conv.updatedAt = message.sentAt;
    if (!m.sender.isMe) conv.unread += 1;
    this.emit("event", "conv.message", { message });
    this.changed(conv);
    return message;
  }

  private updateStatus(message: Message, status: Message["status"]): void {
    message.status = status;
    this.emit("event", "conv.message", { message });
    const conv = this.store.conversations.find((c) => c.id === message.conversationId);
    if (conv?.lastMessage?.id === message.id) {
      conv.lastMessage = message;
      this.changed(conv);
    } else this.save();
  }

  private removeConversation(id: string): void {
    const idx = this.store.conversations.findIndex((c) => c.id === id);
    if (idx < 0) return;
    this.store.conversations.splice(idx, 1);
    delete this.store.messages[id];
    this.emit("event", "conv.removed", { conversationId: id });
    this.save();
  }

  private changed(conv: Conversation): void {
    this.emit("event", "conv.updated", { conversation: conv });
    this.save();
  }

  private save(): void {
    if (this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = undefined;
      try {
        writeJsonAtomic(this.path, this.store);
      } catch (err) {
        this.log(`saving conversations failed: ${(err as Error).message}`);
      }
    }, 250);
    this.saveTimer.unref?.();
  }
}
