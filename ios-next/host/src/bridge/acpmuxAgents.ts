// agent.* served from the cmux-next app's acpmux daemon, so sessions started
// on the Mac show on the phone and the other way round. Phone-facing shapes
// are PROTOCOL.md §4 agents; acpmux shapes come from `cmux acp daemon schema`.

import { EventEmitter } from "node:events";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, resolve as resolvePath } from "node:path";
import type { AgentSession, Harness, SessionStatus } from "../protocol.ts";
import { RpcError, type RpcServer, optStr, str } from "../rpc/index.ts";
import type { Logger } from "../util.ts";
import { JsonRpcSocket } from "./jsonRpcSocket.ts";
import { checkAcpmuxCall } from "./policy.ts";
import { TranscriptBuilder, type AcpmuxEvent } from "./transcript.ts";

interface SessionSummary {
  sessionId: string;
  name: string;
  harness: string;
  family?: string | null;
  cwd: string;
  status: string;
  peer?: string;
  unread?: boolean;
  preview?: string | null;
  lastPrompt?: string | null;
  model?: string | null;
  currentModeId?: string | null;
  createdAt?: number;
  updatedAt?: number;
}

/** Phone status for an acpmux session status. */
export function mapStatus(s: string): SessionStatus {
  switch (s) {
    case "running":
      return "running";
    case "waiting":
      return "waiting";
    case "closed":
      return "closed";
    case "disconnected":
      return "error";
    default:
      return "idle"; // idle, ready
  }
}

export function toAgentSession(s: SessionSummary): AgentSession {
  return {
    id: s.sessionId,
    title: s.name || s.lastPrompt || "Agent session",
    harness: s.family ?? s.harness,
    ...(s.model ? { model: s.model } : {}),
    ...(s.currentModeId ? { mode: s.currentModeId } : {}),
    cwd: s.cwd,
    status: mapStatus(s.status),
    createdAt: s.createdAt ?? Date.now(),
    updatedAt: s.updatedAt ?? s.createdAt ?? Date.now(),
    unread: s.unread ? 1 : 0,
    ...(s.preview ? { preview: s.preview } : {}),
  };
}

const HARNESS_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode", gemini: "Gemini", pi: "pi" };

export interface AcpmuxAgentsEvents {
  event: [topic: string, payload: unknown];
}

/**
 * One acpmux connection for the bridge. Sessions the phone opened
 * (agent.history) are attached so their live records stream in; the watch
 * subscription keeps agent.list current for sessions created on the Mac.
 */
export class AcpmuxAgents extends EventEmitter<AcpmuxAgentsEvents> {
  private rpc: JsonRpcSocket | null = null;
  private connecting: Promise<JsonRpcSocket> | null = null;
  private readonly transcripts = new Map<string, TranscriptBuilder>();
  private readonly summaries = new Map<string, SessionSummary>();
  private readonly log: Logger;

  constructor(
    private readonly socketPath: () => string | null,
    opts: { log?: Logger } = {},
  ) {
    super();
    this.log = opts.log ?? (() => {});
  }

  private async conn(): Promise<JsonRpcSocket> {
    if (this.rpc && !this.rpc.isClosed) return this.rpc;
    if (!this.connecting) {
      this.connecting = (async () => {
        const path = this.socketPath();
        if (!path) throw new RpcError("unavailable", "cmux-next's agent service (acpmux) is not running on this Mac");
        const rpc = await JsonRpcSocket.connect(path);
        rpc.on("notification", (m, p) => this.onNotification(m, p));
        rpc.on("close", (reason) => {
          this.log(`acpmux connection closed: ${reason}`);
          if (this.rpc === rpc) this.rpc = null;
          this.transcripts.clear(); // re-attach (and rebuild) on next history
        });
        await checked(rpc, "initialize", { protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: "cmux-next-host", version: "0.1.0" } }).catch(() => {});
        const watch = await checked<{ sessions: SessionSummary[] }>(rpc, "_acpmux/watch", { enabled: true });
        for (const s of watch.sessions ?? []) this.summaries.set(s.sessionId, s);
        this.rpc = rpc;
        return rpc;
      })().finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  shutdown(): void {
    this.rpc?.close();
  }

  private onNotification(method: string, p: any): void {
    if (method === "_acpmux/session_changed" && p?.session) {
      const s = p.session as SessionSummary;
      if (p.kind === "purged") {
        this.summaries.delete(s.sessionId);
        this.transcripts.delete(s.sessionId);
        this.emit("event", "agent.removed", { sessionId: s.sessionId });
        return;
      }
      this.summaries.set(s.sessionId, s);
      this.emit("event", "agent.session", { session: toAgentSession(s) });
      return;
    }
    if (method === "_acpmux/event" && p && typeof p.seq === "number") {
      const t = this.transcripts.get(p.sessionId);
      if (!t) return;
      for (const item of t.apply(p as AcpmuxEvent)) this.emit("event", "agent.item", { sessionId: p.sessionId, item });
    }
  }

  async harnesses(): Promise<Harness[]> {
    const rpc = await this.conn();
    const [h, models] = await Promise.all([
      checked<{ families?: Record<string, string[]>; harnesses?: Record<string, any> }>(rpc, "_acpmux/harnesses"),
      checked<{ harnesses?: { harness: string; models: { id: string; name: string }[] }[] }>(rpc, "_acpmux/models").catch(() => ({ harnesses: [] })),
    ]);
    const families = Object.keys(h.families ?? {});
    return families.map((family) => {
      const profiles = h.families?.[family] ?? [];
      const ms = (models.harnesses ?? []).filter((m) => m.harness === family || profiles.includes(m.harness)).flatMap((m) => m.models);
      return { id: family, name: HARNESS_NAMES[family] ?? family, available: profiles.length > 0, models: dedupe(ms), modes: [] };
    });
  }

  async list(): Promise<AgentSession[]> {
    const rpc = await this.conn();
    const { sessions } = await checked<{ sessions: SessionSummary[] }>(rpc, "_acpmux/sessions");
    for (const s of sessions) this.summaries.set(s.sessionId, s);
    return sessions.filter((s) => !s.peer).map(toAgentSession).sort((a, b) => b.updatedAt - a.updatedAt);
  }

  async create(p: { harness: string; cwd?: string; model?: string; prompt?: string }): Promise<AgentSession> {
    const rpc = await this.conn();
    const cwd = safeCwd(p.cwd);
    const res = await checked<{ sessionId: string }>(rpc, "session/new", {
      cwd,
      mcpServers: [],
      _meta: { acpmux: { harness: p.harness, ...(p.model ? { model: p.model } : {}) } },
    }, 120_000);
    if (p.prompt) this.sendPrompt(rpc, res.sessionId, p.prompt);
    const { sessions } = await checked<{ sessions: SessionSummary[] }>(rpc, "_acpmux/sessions");
    const s = sessions.find((x) => x.sessionId === res.sessionId);
    if (!s) throw new RpcError("internal", "acpmux did not report the new session");
    this.summaries.set(s.sessionId, s);
    return toAgentSession(s);
  }

  async history(sessionId: string): Promise<{ session: AgentSession; items: unknown[]; commands: { name: string; description: string }[] }> {
    const rpc = await this.conn();
    const res = await checked<{ session: SessionSummary; events: AcpmuxEvent[] }>(rpc, 
      "_acpmux/attach",
      { sessionId, kinds: ["transcript", "available_commands_update"], eventStream: true, limit: 5000 },
      60_000,
    );
    const t = new TranscriptBuilder();
    for (const e of res.events ?? []) t.apply(e);
    this.transcripts.set(res.session.sessionId, t);
    this.summaries.set(res.session.sessionId, res.session);
    return { session: toAgentSession(res.session), items: t.items, commands: t.commands };
  }

  async prompt(sessionId: string, text: string, attachments: { name: string; mimeType: string; dataBase64: string }[]): Promise<void> {
    const rpc = await this.conn();
    const blocks: unknown[] = [{ type: "text", text }];
    for (const a of attachments) if (a.mimeType.startsWith("image/")) blocks.push({ type: "image", mimeType: a.mimeType, data: a.dataBase64 });
    this.sendPrompt(rpc, sessionId, blocks);
  }

  /** session/prompt resolves only when the turn ends; do not hold the phone's request open. */
  private sendPrompt(rpc: JsonRpcSocket, sessionId: string, prompt: string | unknown[]): void {
    const blocks = typeof prompt === "string" ? [{ type: "text", text: prompt }] : prompt;
    checked(rpc, "session/prompt", { sessionId, prompt: blocks }, 0).catch((err) => this.log(`prompt for ${sessionId} failed: ${(err as Error).message}`));
  }

  async cancel(sessionId: string): Promise<void> {
    const rpc = await this.conn();
    checkAcpmuxCall("session/cancel", { sessionId });
    rpc.notify("session/cancel", { sessionId });
  }

  async close(sessionId: string): Promise<void> {
    await checked(await this.conn(), "_acpmux/kill", { sessionId });
  }

  async permission(sessionId: string, itemId: string, optionId: string): Promise<void> {
    if (!itemId.startsWith("perm-")) throw new RpcError("bad_request", "not a permission item");
    await checked(await this.conn(), "_acpmux/permission_respond", { sessionId, permissionId: itemId.slice(5), optionId });
  }

  async setModel(sessionId: string, modelId: string): Promise<void> {
    await checked(await this.conn(), "session/set_model", { sessionId, modelId });
  }

  async setMode(sessionId: string, modeId: string): Promise<void> {
    await checked(await this.conn(), "session/set_mode", { sessionId, modeId });
  }

  async rename(sessionId: string, title: string): Promise<void> {
    await checked(await this.conn(), "_acpmux/rename", { sessionId, newName: title });
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("agent.harnesses", async () => ({ harnesses: await this.harnesses() }));
    server.register("agent.list", async () => ({ sessions: await this.list() }));
    server.register("agent.create", async (p) => ({
      session: await this.create({ harness: str(p, "harness"), cwd: optStr(p, "cwd"), model: optStr(p, "model"), prompt: optStr(p, "prompt") }),
    }));
    server.register("agent.history", (p) => this.history(str(p, "sessionId")));
    server.register("agent.prompt", async (p) => {
      await this.prompt(str(p, "sessionId"), typeof p.text === "string" ? p.text : "", Array.isArray(p.attachments) ? p.attachments : []);
      return {};
    });
    server.register("agent.cancel", async (p) => (await this.cancel(str(p, "sessionId")), {}));
    server.register("agent.close", async (p) => (await this.close(str(p, "sessionId")), {}));
    server.register("agent.permission", async (p) => (await this.permission(str(p, "sessionId"), str(p, "itemId"), str(p, "optionId")), {}));
    server.register("agent.setModel", async (p) => (await this.setModel(str(p, "sessionId"), str(p, "modelId")), {}));
    server.register("agent.setMode", async (p) => (await this.setMode(str(p, "sessionId"), str(p, "modeId")), {}));
    server.register("agent.rename", async (p) => (await this.rename(str(p, "sessionId"), str(p, "title")), {}));
  }
}

/** Every acpmux call goes through the bridge policy first. */
function checked<T = any>(rpc: JsonRpcSocket, method: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<T> {
  try {
    checkAcpmuxCall(method, params);
  } catch (err) {
    return Promise.reject(err);
  }
  return rpc.request<T>(method, params, timeoutMs);
}

function dedupe(ms: { id: string; name: string }[]): { id: string; name: string }[] {
  const seen = new Set<string>();
  return ms.filter((m) => (seen.has(m.id) ? false : (seen.add(m.id), true)));
}

/**
 * An agent's working directory: an existing directory inside the user's home
 * (the phone cannot point an agent at system paths). Defaults to home.
 */
export function safeCwd(cwd: string | undefined): string {
  const home = homedir();
  if (!cwd) return home;
  const abs = isAbsolute(cwd) ? resolvePath(cwd) : resolvePath(home, cwd);
  if (abs !== home && !abs.startsWith(home + "/")) throw new RpcError("bad_request", "cwd must be inside your home folder");
  if (!existsSync(abs) || !statSync(abs).isDirectory()) throw new RpcError("bad_request", "cwd is not a directory");
  return abs;
}
