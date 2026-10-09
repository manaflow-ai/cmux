// ACP agent sessions (PROTOCOL.md §4 agents). Each session runs its own ACP
// agent subprocess. session/update notifications are mapped to TranscriptItems
// that are upserted by id. Transcripts persist to
// ~/.cmux-next-host/sessions/<id>.jsonl and reload after a host restart.

import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { appendFileSync, existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";
import type { AgentSession, Harness, SessionStatus, ToolKindP, TranscriptItem } from "../protocol.ts";
import { RpcError, type RpcServer, optStr, str } from "../rpc/index.ts";
import { childEnv, ensureDir, newId, stateDir, type Logger } from "../util.ts";
import { defaultHarnesses, type HarnessSpec } from "./harnesses.ts";

type Item = TranscriptItem;
type ToolItem = Extract<Item, { kind: "tool" }>;
type TextItem = Extract<Item, { kind: "assistant" | "thought" }>;

const MAX_OUTPUT = 32 * 1024;
const MAX_INPUT = 8 * 1024;
const STREAM_EMIT_MS = 50;

interface Choice {
  id: string;
  name: string;
}

interface AcpProcess {
  proc: ChildProcess;
  conn: acp.ClientSideConnection;
  init: acp.InitializeResponse;
  stderrTail: string[];
  exited: boolean;
}

interface TurnState {
  startedAt: number;
  userItemId: string;
  assistantId?: string;
  assistantMessageId?: string;
  thoughtId?: string;
  thoughtStartedAt?: number;
  planId?: string;
}

interface SessionState {
  meta: AgentSession;
  hidden: boolean;
  items: Item[];
  index: Map<string, number>;
  commands: { name: string; description: string }[];
  models: Choice[];
  modes: Choice[];
  modelConfigId?: string;
  modeConfigId?: string;
  acpSessionId?: string;
  proc?: AcpProcess;
  starting?: Promise<void>;
  turn?: TurnState;
  turnCount: number;
  itemSeq: number;
  permissions: Map<string, (optionId: string | null) => void>;
  loadingHistory: boolean;
  pendingEmits: Map<string, NodeJS.Timeout>;
  dirtyItems: Set<string>;
  metaDirty: boolean;
  flushTimer?: NodeJS.Timeout;
}

export interface TurnEndInfo {
  sessionId: string;
  stopReason: string;
  /** Assistant message texts of the finished turn, in order. */
  texts: string[];
  hidden: boolean;
}

export interface AgentsProviderEvents {
  event: [topic: string, payload: unknown];
  /** Session metadata changed (also for hidden sessions). */
  session: [session: AgentSession, hidden: boolean];
  userPrompt: [sessionId: string, text: string, hidden: boolean];
  turnEnd: [info: TurnEndInfo];
}

export interface AgentsProviderOptions {
  harnesses?: HarnessSpec[];
  dir?: string;
  log?: Logger;
  /** Availability cache lifetime. */
  detectTtlMs?: number;
}

export class AgentsProvider extends EventEmitter<AgentsProviderEvents> {
  readonly harnessSpecs: HarnessSpec[];
  private readonly sessions = new Map<string, SessionState>();
  private readonly byAcpId = new Map<string, SessionState>();
  private readonly dir: string;
  private readonly log: Logger;
  private availability = new Map<string, { at: number; value: boolean }>();
  private harnessChoices = new Map<string, { models: Choice[]; modes: Choice[] }>();
  private readonly detectTtlMs: number;

  constructor(opts: AgentsProviderOptions = {}) {
    super();
    this.harnessSpecs = opts.harnesses ?? defaultHarnesses();
    this.dir = opts.dir ?? join(stateDir(), "sessions");
    this.log = opts.log ?? (() => {});
    this.detectTtlMs = opts.detectTtlMs ?? 60_000;
    this.load();
  }

  // ---------------------------------------------------------------- harnesses

  async isAvailable(harnessId: string): Promise<boolean> {
    const spec = this.harnessSpecs.find((h) => h.id === harnessId);
    if (!spec) return false;
    const cached = this.availability.get(harnessId);
    if (cached && Date.now() - cached.at < this.detectTtlMs) return cached.value;
    let value = false;
    try {
      value = await spec.detect();
    } catch {
      value = false;
    }
    this.availability.set(harnessId, { at: Date.now(), value });
    return value;
  }

  async harnesses(): Promise<Harness[]> {
    return Promise.all(
      this.harnessSpecs.map(async (h) => ({
        id: h.id,
        name: h.name,
        available: await this.isAvailable(h.id),
        models: this.harnessChoices.get(h.id)?.models ?? [],
        modes: this.harnessChoices.get(h.id)?.modes ?? [],
      })),
    );
  }

  /** First available harness among preferred ids. */
  async pickHarness(preferred: string[]): Promise<string | null> {
    for (const id of preferred) if (await this.isAvailable(id)) return id;
    return null;
  }

  spec(harnessId: string): HarnessSpec | undefined {
    return this.harnessSpecs.find((h) => h.id === harnessId);
  }

  // ---------------------------------------------------------------- sessions

  list(includeHidden = false): AgentSession[] {
    return [...this.sessions.values()]
      .filter((s) => includeHidden || !s.hidden)
      .map((s) => ({ ...s.meta }))
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }

  getMeta(id: string): AgentSession | undefined {
    const s = this.sessions.get(id);
    return s ? { ...s.meta } : undefined;
  }

  history(id: string): { session: AgentSession; items: Item[]; commands: { name: string; description: string }[] } {
    const s = this.get(id);
    if (s.meta.unread > 0) {
      s.meta.unread = 0;
      this.touchMeta(s, false);
    }
    return { session: { ...s.meta }, items: s.items.map((i) => ({ ...i })), commands: [...s.commands] };
  }

  async create(opts: { harness: string; cwd?: string; model?: string; prompt?: string; hidden?: boolean; title?: string }): Promise<AgentSession> {
    const spec = this.spec(opts.harness);
    if (!spec) throw new RpcError("bad_request", `unknown harness ${opts.harness}`);
    if (!(await this.isAvailable(spec.id))) {
      throw new RpcError("unavailable", `${spec.name} is not installed or not logged in on this Mac`);
    }
    const cwd = opts.cwd && existsSync(opts.cwd) && statSync(opts.cwd).isDirectory() ? opts.cwd : homedir();
    const now = Date.now();
    const title = opts.title ?? (opts.prompt ? titleFrom(opts.prompt) : `New ${spec.name} session`);
    const s = this.newState({
      id: newId("a"),
      title,
      harness: spec.id,
      cwd,
      status: opts.prompt ? "running" : "idle",
      createdAt: now,
      updatedAt: now,
      unread: 0,
    }, Boolean(opts.hidden));
    this.sessions.set(s.meta.id, s);
    this.touchMeta(s);
    void (async () => {
      try {
        await this.ensureStarted(s);
        if (opts.model) await this.setModel(s.meta.id, opts.model).catch(() => {});
        if (opts.prompt) await this.prompt(s.meta.id, opts.prompt, [], true);
      } catch (err) {
        this.fail(s, err);
      }
    })();
    return { ...s.meta };
  }

  /** Sends a user prompt. Resolves once the turn has started (not finished). */
  async prompt(
    id: string,
    text: string,
    attachments: { name: string; mimeType: string; dataBase64: string }[] = [],
    allowRunning = false,
  ): Promise<void> {
    const s = this.get(id);
    if (!allowRunning && (s.turn || s.meta.status === "running" || s.meta.status === "waiting")) {
      throw new RpcError("unavailable", "the agent is still working on the previous prompt");
    }
    const userItem: Item = {
      id: this.itemId(s),
      kind: "user",
      text,
      attachments: attachments.map((a) => ({ name: a.name, mimeType: a.mimeType })),
    };
    s.turnCount += 1;
    s.turn = { startedAt: Date.now(), userItemId: userItem.id };
    this.upsert(s, userItem, true);
    if (s.meta.title.startsWith("New ") && text.trim()) s.meta.title = titleFrom(text);
    s.meta.status = "running";
    this.touchMeta(s);
    this.emit("userPrompt", s.meta.id, text, s.hidden);

    try {
      await this.ensureStarted(s);
    } catch (err) {
      this.fail(s, err);
      return;
    }
    const proc = s.proc!;
    const blocks: acp.ContentBlock[] = [{ type: "text", text }];
    for (const a of attachments) {
      if (a.mimeType.startsWith("image/")) blocks.push({ type: "image", mimeType: a.mimeType, data: a.dataBase64 });
      else if (/^text\/|json|xml|javascript|yaml/.test(a.mimeType)) {
        blocks.push({
          type: "resource",
          resource: { uri: `file:///${encodeURIComponent(a.name)}`, mimeType: a.mimeType, text: Buffer.from(a.dataBase64, "base64").toString("utf8") },
        });
      }
    }
    proc.conn
      .prompt({ sessionId: s.acpSessionId!, prompt: blocks })
      .then((res) => this.endTurn(s, res.stopReason ?? "end_turn"))
      .catch((err) => {
        this.addNotice(s, "error", errorText(err, proc));
        this.endTurn(s, "error");
      });
  }

  async cancel(id: string): Promise<void> {
    const s = this.get(id);
    for (const [, resolve] of s.permissions) resolve(null);
    s.permissions.clear();
    if (s.proc && s.acpSessionId && s.turn) {
      await s.proc.conn.cancel({ sessionId: s.acpSessionId }).catch(() => {});
    }
  }

  close(id: string): void {
    const s = this.get(id);
    for (const [, resolve] of s.permissions) resolve(null);
    s.permissions.clear();
    this.killProcess(s);
    if (s.turn) this.endTurn(s, "cancelled");
    s.meta.status = "closed";
    this.touchMeta(s);
  }

  /** Removes a session and its transcript file. */
  remove(id: string): void {
    const s = this.sessions.get(id);
    if (!s) return;
    this.killProcess(s);
    this.sessions.delete(id);
    if (s.acpSessionId) this.byAcpId.delete(s.acpSessionId);
    try {
      writeFileSync(this.file(id), "");
    } catch {}
    if (!s.hidden) this.emit("event", "agent.removed", { sessionId: id });
  }

  permission(id: string, itemId: string, optionId: string): void {
    const s = this.get(id);
    const resolve = s.permissions.get(itemId);
    if (!resolve) throw new RpcError("not_found", `no pending permission ${itemId}`);
    const idx = s.index.get(itemId);
    const item = idx !== undefined ? s.items[idx] : undefined;
    if (item?.kind === "permission" && !item.options.some((o) => o.id === optionId)) {
      throw new RpcError("bad_request", `unknown option ${optionId}`);
    }
    s.permissions.delete(itemId);
    resolve(optionId);
  }

  async setModel(id: string, modelId: string): Promise<void> {
    const s = this.get(id);
    await this.ensureStarted(s);
    const conn = s.proc!.conn;
    if (s.modelConfigId) {
      const res = await conn.setSessionConfigOption({ sessionId: s.acpSessionId!, configId: s.modelConfigId, value: modelId });
      this.applyConfigOptions(s, res.configOptions);
    } else {
      await conn.extMethod("session/set_model", { sessionId: s.acpSessionId!, modelId });
    }
    s.meta.model = modelId;
    this.touchMeta(s);
  }

  async setMode(id: string, modeId: string): Promise<void> {
    const s = this.get(id);
    await this.ensureStarted(s);
    const conn = s.proc!.conn;
    if (s.modeConfigId) {
      const res = await conn.setSessionConfigOption({ sessionId: s.acpSessionId!, configId: s.modeConfigId, value: modeId });
      this.applyConfigOptions(s, res.configOptions);
    } else {
      await conn.setSessionMode({ sessionId: s.acpSessionId!, modeId });
    }
    s.meta.mode = modeId;
    this.touchMeta(s);
  }

  rename(id: string, title: string): void {
    const s = this.get(id);
    s.meta.title = title;
    this.touchMeta(s);
  }

  /** Last assistant text of the session (for previews). */
  lastAssistantText(id: string): string | undefined {
    const s = this.sessions.get(id);
    if (!s) return undefined;
    for (let i = s.items.length - 1; i >= 0; i--) {
      const it = s.items[i]!;
      if (it.kind === "assistant" && it.text.trim()) return it.text;
    }
    return undefined;
  }

  shutdown(): void {
    for (const s of this.sessions.values()) {
      this.flush(s);
      this.killProcess(s);
    }
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("agent.harnesses", async () => ({ harnesses: await this.harnesses() }));
    server.register("agent.list", () => ({ sessions: this.list() }));
    server.register("agent.create", async (p) => ({
      session: await this.create({ harness: str(p, "harness"), cwd: optStr(p, "cwd"), model: optStr(p, "model"), prompt: optStr(p, "prompt") }),
    }));
    server.register("agent.history", (p) => this.history(str(p, "sessionId")));
    server.register("agent.prompt", async (p) => {
      const attachments = Array.isArray(p.attachments) ? p.attachments : [];
      await this.prompt(str(p, "sessionId"), typeof p.text === "string" ? p.text : "", attachments);
      return {};
    });
    server.register("agent.cancel", async (p) => {
      await this.cancel(str(p, "sessionId"));
      return {};
    });
    server.register("agent.close", (p) => {
      this.close(str(p, "sessionId"));
      return {};
    });
    server.register("agent.permission", (p) => {
      this.permission(str(p, "sessionId"), str(p, "itemId"), str(p, "optionId"));
      return {};
    });
    server.register("agent.setModel", async (p) => {
      await this.setModel(str(p, "sessionId"), str(p, "modelId"));
      return {};
    });
    server.register("agent.setMode", async (p) => {
      await this.setMode(str(p, "sessionId"), str(p, "modeId"));
      return {};
    });
    server.register("agent.rename", (p) => {
      this.rename(str(p, "sessionId"), str(p, "title"));
      return {};
    });
  }

  // ---------------------------------------------------------------- internals

  private get(id: string): SessionState {
    const s = this.sessions.get(id);
    if (!s) throw new RpcError("not_found", `session ${id} not found`);
    return s;
  }

  private newState(meta: AgentSession, hidden: boolean): SessionState {
    return {
      meta,
      hidden,
      items: [],
      index: new Map(),
      commands: [],
      models: [],
      modes: [],
      turnCount: 0,
      itemSeq: 0,
      permissions: new Map(),
      loadingHistory: false,
      pendingEmits: new Map(),
      dirtyItems: new Set(),
      metaDirty: true,
    };
  }

  private itemId(s: SessionState): string {
    s.itemSeq += 1;
    return `i${s.itemSeq}`;
  }

  private ensureStarted(s: SessionState): Promise<void> {
    if (s.proc && !s.proc.exited) return Promise.resolve();
    if (!s.starting) {
      s.starting = this.start(s).finally(() => {
        s.starting = undefined;
      });
    }
    return s.starting;
  }

  private async start(s: SessionState): Promise<void> {
    const spec = this.spec(s.meta.harness);
    if (!spec) throw new Error(`unknown harness ${s.meta.harness}`);
    this.log(`starting ${spec.id} agent for ${s.meta.id}: ${spec.command} ${spec.args.join(" ")}`);
    const proc = spawn(spec.command, spec.args, {
      cwd: s.meta.cwd,
      env: childEnv(spec.env),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const ap: AcpProcess = { proc, conn: undefined as unknown as acp.ClientSideConnection, init: undefined as unknown as acp.InitializeResponse, stderrTail: [], exited: false };
    proc.stderr!.setEncoding("utf8");
    proc.stderr!.on("data", (chunk: string) => {
      for (const line of chunk.split("\n")) {
        if (!line.trim()) continue;
        ap.stderrTail.push(line);
        if (ap.stderrTail.length > 30) ap.stderrTail.shift();
      }
    });
    const exited = new Promise<never>((_, reject) => {
      proc.on("error", (err) => {
        ap.exited = true;
        reject(err);
      });
      proc.on("exit", (code, signal) => {
        ap.exited = true;
        this.onProcessExit(s, ap, code, signal);
        reject(new Error(`agent exited (${code ?? signal}) ${ap.stderrTail.slice(-3).join(" | ")}`));
      });
    });
    exited.catch(() => {});
    const stream = acp.ndJsonStream(
      Writable.toWeb(proc.stdin!) as WritableStream<Uint8Array>,
      Readable.toWeb(proc.stdout!) as unknown as ReadableStream<Uint8Array>,
    );
    ap.conn = new acp.ClientSideConnection(() => this.clientFor(s), stream);
    ap.init = await Promise.race([
      ap.conn.initialize({
        protocolVersion: acp.PROTOCOL_VERSION,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
        clientInfo: { name: "cmux-next-host", version: "0.1.0" },
      } as acp.InitializeRequest),
      exited,
    ]);
    s.proc = ap;

    let restored = false;
    if (s.acpSessionId) {
      const caps = ap.init.agentCapabilities ?? {};
      try {
        if (caps.loadSession) {
          s.loadingHistory = true;
          this.byAcpId.set(s.acpSessionId, s);
          const res = await Promise.race([ap.conn.loadSession({ sessionId: s.acpSessionId, cwd: s.meta.cwd, mcpServers: [] }), exited]);
          this.applySessionSetup(s, res as acp.NewSessionResponse);
          restored = true;
        } else if (caps.sessionCapabilities?.resume) {
          this.byAcpId.set(s.acpSessionId, s);
          const res = await Promise.race([ap.conn.resumeSession({ sessionId: s.acpSessionId, cwd: s.meta.cwd, mcpServers: [] } as acp.ResumeSessionRequest), exited]);
          this.applySessionSetup(s, res as acp.NewSessionResponse);
          restored = true;
        }
      } catch (err) {
        this.log(`could not restore ${s.meta.id}: ${(err as Error).message}`);
      } finally {
        s.loadingHistory = false;
      }
      if (!restored) {
        this.byAcpId.delete(s.acpSessionId);
        this.addNotice(s, "info", "The previous agent context could not be restored; continuing in a fresh session.");
      }
    }
    if (!restored) {
      const res = await Promise.race([ap.conn.newSession({ cwd: s.meta.cwd, mcpServers: [] }), exited]);
      s.acpSessionId = res.sessionId;
      this.byAcpId.set(res.sessionId, s);
      this.applySessionSetup(s, res);
    }
    if (s.meta.status === "closed" || s.meta.status === "error") s.meta.status = s.turn ? "running" : "idle";
    this.touchMeta(s);
  }

  private applySessionSetup(s: SessionState, res: acp.NewSessionResponse | undefined): void {
    if (!res) return;
    const anyRes = res as acp.NewSessionResponse & {
      models?: { currentModelId?: string; availableModels?: { modelId: string; name?: string }[] } | null;
    };
    if (anyRes.models?.availableModels) {
      s.models = anyRes.models.availableModels.map((m) => ({ id: m.modelId, name: m.name ?? m.modelId }));
      if (anyRes.models.currentModelId) s.meta.model = anyRes.models.currentModelId;
    }
    if (res.modes) {
      s.modes = res.modes.availableModes.map((m) => ({ id: m.id, name: m.name ?? m.id }));
      s.meta.mode = res.modes.currentModeId;
    }
    this.applyConfigOptions(s, res.configOptions);
    this.harnessChoices.set(s.meta.harness, { models: s.models, modes: s.modes });
  }

  private applyConfigOptions(s: SessionState, options: acp.SessionConfigOption[] | null | undefined): void {
    if (!options) return;
    for (const opt of options) {
      if (opt.type !== "select") continue;
      const sel = opt as unknown as { currentValue: string; options: unknown[] };
      const flat: Choice[] = [];
      for (const o of sel.options as Array<{ value?: string; name?: string; options?: { value: string; name: string }[] }>) {
        if (o.options) for (const x of o.options) flat.push({ id: x.value, name: x.name });
        else if (o.value) flat.push({ id: o.value, name: o.name ?? o.value });
      }
      if (opt.category === "model" || opt.id === "model") {
        s.modelConfigId = opt.id;
        s.models = flat;
        s.meta.model = sel.currentValue;
      } else if (opt.category === "mode" || opt.id === "mode") {
        s.modeConfigId = opt.id;
        s.modes = flat;
        s.meta.mode = sel.currentValue;
      }
    }
    this.harnessChoices.set(s.meta.harness, { models: s.models, modes: s.modes });
  }

  private clientFor(s: SessionState): acp.Client {
    return {
      sessionUpdate: async (params) => {
        const target = this.byAcpId.get(params.sessionId) ?? s;
        this.onUpdate(target, params.update);
      },
      requestPermission: (params) => this.onPermission(s, params),
    };
  }

  private onProcessExit(s: SessionState, ap: AcpProcess, code: number | null, signal: NodeJS.Signals | null): void {
    if (s.proc !== ap) return;
    s.proc = undefined;
    this.log(`agent for ${s.meta.id} exited (${code ?? signal})`);
    for (const [, resolve] of s.permissions) resolve(null);
    s.permissions.clear();
    if (s.turn) {
      this.addNotice(s, "error", `The agent process exited unexpectedly (${code ?? signal}). ${ap.stderrTail.slice(-3).join(" ")}`.trim());
      this.endTurn(s, "error");
    }
  }

  private fail(s: SessionState, err: unknown): void {
    this.addNotice(s, "error", errorText(err, s.proc));
    if (s.turn) this.endTurn(s, "error");
    s.meta.status = "error";
    this.touchMeta(s);
  }

  // Map ACP session/update into transcript items.
  private onUpdate(s: SessionState, u: acp.SessionUpdate): void {
    if (s.loadingHistory) return; // we already have our own transcript
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        const text = u.content.type === "text" ? u.content.text : u.content.type === "image" ? "\n[image]\n" : "";
        if (!text) return;
        if (u.sessionUpdate === "agent_message_chunk") this.appendText(s, "assistant", text, u.messageId ?? undefined);
        else this.appendText(s, "thought", text, undefined);
        return;
      }
      case "user_message_chunk":
        return;
      case "tool_call": {
        this.finalizeStreaming(s);
        const item: ToolItem = {
          id: `tool-${u.toolCallId}`,
          kind: "tool",
          toolKind: mapToolKind(u.kind),
          title: u.title || u.name || "Tool",
          status: mapToolStatus(u.status),
          locations: (u.locations ?? []).map((l) => ({ path: l.path, ...(l.line != null ? { line: l.line } : {}) })),
        };
        applyToolContent(item, u.content, u.rawInput, u.rawOutput);
        this.upsert(s, item, true);
        return;
      }
      case "tool_call_update": {
        const id = `tool-${u.toolCallId}`;
        const idx = s.index.get(id);
        const existing = idx !== undefined ? (s.items[idx] as ToolItem) : undefined;
        const item: ToolItem = existing
          ? { ...existing }
          : { id, kind: "tool", toolKind: "other", title: "Tool", status: "pending", locations: [] };
        if (u.kind) item.toolKind = mapToolKind(u.kind);
        if (u.title) item.title = u.title;
        if (u.status) item.status = mapToolStatus(u.status);
        if (u.locations) item.locations = u.locations.map((l) => ({ path: l.path, ...(l.line != null ? { line: l.line } : {}) }));
        applyToolContent(item, u.content ?? undefined, u.rawInput, u.rawOutput);
        if (!existing) this.finalizeStreaming(s);
        this.upsert(s, item, true);
        return;
      }
      case "plan": {
        this.finalizeStreaming(s);
        const turn = s.turn;
        const id = turn?.planId ?? `plan-${s.turnCount}`;
        if (turn) turn.planId = id;
        this.upsert(
          s,
          {
            id,
            kind: "plan",
            entries: u.entries.map((e) => ({ content: e.content, status: e.status as "pending" | "in_progress" | "completed", priority: e.priority })),
          },
          true,
        );
        return;
      }
      case "available_commands_update":
        s.commands = u.availableCommands.map((c) => ({ name: c.name, description: c.description }));
        return;
      case "current_mode_update":
        s.meta.mode = u.currentModeId;
        this.touchMeta(s);
        return;
      case "config_option_update":
        this.applyConfigOptions(s, (u as { configOptions?: acp.SessionConfigOption[] }).configOptions);
        this.touchMeta(s);
        return;
      case "session_info_update": {
        const title = (u as { title?: string | null }).title;
        if (title) {
          s.meta.title = title;
          this.touchMeta(s);
        }
        return;
      }
      case "notice": {
        const n = u as unknown as { message?: string; text?: string; level?: string };
        const text = n.message ?? n.text;
        if (text) this.addNotice(s, n.level === "error" ? "error" : n.level === "warning" ? "warning" : "info", text);
        return;
      }
      default:
        return;
    }
  }

  private appendText(s: SessionState, kind: "assistant" | "thought", text: string, messageId?: string): void {
    const turn = s.turn;
    const last = s.items[s.items.length - 1];
    const currentId = kind === "assistant" ? turn?.assistantId : turn?.thoughtId;
    const sameMessage = kind !== "assistant" || !messageId || !turn?.assistantMessageId || turn.assistantMessageId === messageId;
    if (currentId && last && last.id === currentId && sameMessage) {
      const item = last as TextItem;
      item.text += text;
      this.scheduleEmit(s, item);
      return;
    }
    this.finalizeStreaming(s);
    const id = this.itemId(s);
    const item: TextItem = kind === "assistant" ? { id, kind, text, streaming: true } : { id, kind, text, streaming: true };
    if (turn) {
      if (kind === "assistant") {
        turn.assistantId = id;
        turn.assistantMessageId = messageId;
      } else {
        turn.thoughtId = id;
        turn.thoughtStartedAt = Date.now();
      }
    }
    this.upsert(s, item, true);
  }

  /** Marks the open assistant/thought item as complete. */
  private finalizeStreaming(s: SessionState): void {
    const turn = s.turn;
    if (!turn) return;
    for (const id of [turn.assistantId, turn.thoughtId]) {
      if (!id) continue;
      const idx = s.index.get(id);
      const item = idx !== undefined ? (s.items[idx] as TextItem) : undefined;
      if (item && item.streaming) {
        item.streaming = false;
        if (item.kind === "thought" && turn.thoughtStartedAt) item.durationMs = Date.now() - turn.thoughtStartedAt;
        this.upsert(s, item, true);
      }
    }
    turn.assistantId = undefined;
    turn.thoughtId = undefined;
  }

  private async onPermission(s: SessionState, params: acp.RequestPermissionRequest): Promise<acp.RequestPermissionResponse> {
    const target = this.byAcpId.get(params.sessionId) ?? s;
    this.finalizeStreaming(target);
    const tc = params.toolCall;
    const toolId = `tool-${tc.toolCallId}`;
    const toolIdx = target.index.get(toolId);
    if (toolIdx === undefined && (tc.title || tc.kind)) {
      const item: ToolItem = {
        id: toolId,
        kind: "tool",
        toolKind: mapToolKind(tc.kind ?? undefined),
        title: tc.title ?? "Tool",
        status: "pending",
        locations: (tc.locations ?? []).map((l) => ({ path: l.path, ...(l.line != null ? { line: l.line } : {}) })),
      };
      applyToolContent(item, tc.content ?? undefined, tc.rawInput, tc.rawOutput);
      this.upsert(target, item, true);
    }
    const existingTitle = toolIdx !== undefined ? (target.items[toolIdx] as ToolItem).title : undefined;
    const itemId = `perm-${this.itemId(target)}`;
    const item: Extract<Item, { kind: "permission" }> = {
      id: itemId,
      kind: "permission",
      toolCallId: tc.toolCallId,
      title: tc.title ?? existingTitle ?? "Permission requested",
      options: params.options.map((o) => ({ id: o.optionId, name: o.name, kind: o.kind as "allow_once" })),
    };
    this.upsert(target, item, true);
    target.meta.status = "waiting";
    this.touchMeta(target);
    const optionId = await new Promise<string | null>((resolve) => target.permissions.set(itemId, resolve));
    // Cancel, turn end and agent exit resolve pending permissions with null.
    item.resolved = optionId ?? "cancelled";
    if (optionId === null) {
      this.upsert(target, item, true);
      return { outcome: { outcome: "cancelled" } };
    }
    this.upsert(target, item, true);
    if (target.turn) target.meta.status = "running";
    this.touchMeta(target);
    return { outcome: { outcome: "selected", optionId } };
  }

  private endTurn(s: SessionState, stopReason: string): void {
    const turn = s.turn;
    if (!turn) return;
    this.finalizeStreaming(s);
    s.turn = undefined;
    for (const [, resolve] of s.permissions) resolve(null);
    s.permissions.clear();
    this.upsert(s, { id: this.itemId(s), kind: "turnEnd", stopReason, durationMs: Date.now() - turn.startedAt }, true);
    const userIdx = s.index.get(turn.userItemId) ?? 0;
    const texts = s.items
      .slice(userIdx + 1)
      .filter((i): i is Extract<Item, { kind: "assistant" }> => i.kind === "assistant")
      .map((i) => i.text.trim())
      .filter(Boolean);
    if (texts.length > 0) s.meta.preview = previewOf(texts[texts.length - 1]!);
    if (s.meta.status !== "closed") s.meta.status = stopReason === "error" ? "error" : "idle";
    s.meta.unread += 1;
    this.touchMeta(s);
    this.emit("turnEnd", { sessionId: s.meta.id, stopReason, texts, hidden: s.hidden });
  }

  private addNotice(s: SessionState, level: "info" | "warning" | "error", text: string): void {
    this.finalizeStreaming(s);
    this.upsert(s, { id: this.itemId(s), kind: "notice", level, text }, true);
  }

  private upsert(s: SessionState, item: Item, immediate: boolean): void {
    const idx = s.index.get(item.id);
    if (idx === undefined) {
      s.index.set(item.id, s.items.length);
      s.items.push(item);
    } else {
      s.items[idx] = item;
    }
    s.dirtyItems.add(item.id);
    this.scheduleFlush(s);
    if (immediate) this.emitItem(s, item);
    else this.scheduleEmit(s, item);
  }

  private scheduleEmit(s: SessionState, item: Item): void {
    s.dirtyItems.add(item.id);
    this.scheduleFlush(s);
    if (s.pendingEmits.has(item.id)) return;
    s.pendingEmits.set(
      item.id,
      setTimeout(() => {
        s.pendingEmits.delete(item.id);
        const idx = s.index.get(item.id);
        if (idx !== undefined) this.emitItem(s, s.items[idx]!);
      }, STREAM_EMIT_MS),
    );
  }

  private emitItem(s: SessionState, item: Item): void {
    const pending = s.pendingEmits.get(item.id);
    if (pending) {
      clearTimeout(pending);
      s.pendingEmits.delete(item.id);
    }
    if (!s.hidden) this.emit("event", "agent.item", { sessionId: s.meta.id, item: { ...item } });
  }

  private touchMeta(s: SessionState, bumpUpdated = true): void {
    if (bumpUpdated) s.meta.updatedAt = Date.now();
    s.metaDirty = true;
    this.scheduleFlush(s);
    if (!s.hidden) this.emit("event", "agent.session", { session: { ...s.meta } });
    this.emit("session", { ...s.meta }, s.hidden);
  }

  private killProcess(s: SessionState): void {
    const ap = s.proc;
    s.proc = undefined;
    if (ap && !ap.exited) {
      try {
        ap.proc.kill("SIGTERM");
      } catch {}
    }
  }

  // ---------------------------------------------------------------- persistence

  private file(id: string): string {
    return join(this.dir, `${id}.jsonl`);
  }

  private scheduleFlush(s: SessionState): void {
    if (s.flushTimer) return;
    s.flushTimer = setTimeout(() => this.flush(s), 300);
    s.flushTimer.unref?.();
  }

  private flush(s: SessionState): void {
    if (s.flushTimer) clearTimeout(s.flushTimer);
    s.flushTimer = undefined;
    if (!this.sessions.has(s.meta.id)) return;
    const lines: string[] = [];
    if (s.metaDirty) {
      lines.push(JSON.stringify({ type: "session", session: s.meta, hidden: s.hidden, acpSessionId: s.acpSessionId, itemSeq: s.itemSeq, turnCount: s.turnCount }));
      s.metaDirty = false;
    }
    for (const id of s.dirtyItems) {
      const idx = s.index.get(id);
      if (idx !== undefined) lines.push(JSON.stringify({ type: "item", item: s.items[idx] }));
    }
    s.dirtyItems.clear();
    if (lines.length === 0) return;
    try {
      ensureDir(this.dir);
      appendFileSync(this.file(s.meta.id), lines.join("\n") + "\n");
    } catch (err) {
      this.log(`persist failed: ${(err as Error).message}`);
    }
  }

  private load(): void {
    if (!existsSync(this.dir)) return;
    for (const name of readdirSync(this.dir)) {
      if (!name.endsWith(".jsonl")) continue;
      let s: SessionState | undefined;
      try {
        const lines = readFileSync(join(this.dir, name), "utf8").split("\n");
        for (const line of lines) {
          if (!line.trim()) continue;
          let rec: any;
          try {
            rec = JSON.parse(line);
          } catch {
            continue;
          }
          if (rec.type === "session") {
            if (!s) s = this.newState(rec.session, Boolean(rec.hidden));
            s.meta = rec.session;
            s.hidden = Boolean(rec.hidden);
            s.acpSessionId = rec.acpSessionId ?? s.acpSessionId;
            s.itemSeq = Math.max(s.itemSeq, rec.itemSeq ?? 0);
            s.turnCount = Math.max(s.turnCount, rec.turnCount ?? 0);
          } else if (rec.type === "item" && s) {
            const idx = s.index.get(rec.item.id);
            if (idx === undefined) {
              s.index.set(rec.item.id, s.items.length);
              s.items.push(rec.item);
            } else s.items[idx] = rec.item;
          }
        }
      } catch {
        continue;
      }
      if (!s) continue;
      // Sessions reload without a live process: running turns are over.
      for (const it of s.items) if ((it.kind === "assistant" || it.kind === "thought") && it.streaming) it.streaming = false;
      // A permission that was pending when the host stopped can no longer be answered.
      for (const it of s.items) if (it.kind === "permission" && it.resolved === undefined) it.resolved = "cancelled";
      if (s.meta.status !== "closed") s.meta.status = "idle";
      for (const it of s.items) {
        const m = /^i(\d+)$/.exec(it.id.replace(/^perm-/, ""));
        if (m) s.itemSeq = Math.max(s.itemSeq, Number(m[1]));
      }
      this.sessions.set(s.meta.id, s);
      // Compact the file.
      s.metaDirty = true;
      for (const it of s.items) s.dirtyItems.add(it.id);
      try {
        writeFileSync(this.file(s.meta.id), "");
      } catch {}
      this.flush(s);
    }
  }
}

// ---------------------------------------------------------------- helpers

function titleFrom(text: string): string {
  const line = text.trim().split("\n")[0] ?? "";
  return line.length > 60 ? `${line.slice(0, 57)}...` : line || "New session";
}

function previewOf(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > 140 ? `${flat.slice(0, 137)}...` : flat;
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}\n... (${text.length - max} more characters)` : text;
}

function errorText(err: unknown, proc?: AcpProcess): string {
  const e = err as { message?: string; data?: unknown; code?: unknown };
  let msg = e?.message ?? String(err);
  if (e?.data) msg += ` ${typeof e.data === "string" ? e.data : JSON.stringify(e.data)}`;
  if (/auth/i.test(msg)) msg += " (log in to the agent CLI on the Mac)";
  const tail = proc?.stderrTail.slice(-2).join(" ");
  return tail ? `${msg} [${tail}]` : msg;
}

export function mapToolKind(kind: string | undefined | null): ToolKindP {
  switch (kind) {
    case "read":
    case "edit":
    case "execute":
    case "search":
    case "fetch":
    case "delete":
    case "think":
      return kind;
    case "move":
      return "edit";
    default:
      return "other";
  }
}

export function mapToolStatus(status: string | undefined | null): ToolItem["status"] {
  switch (status) {
    case "in_progress":
      return "running";
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    default:
      return "pending";
  }
}

function stringifyInput(raw: unknown): string | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw === "string") return truncate(raw, MAX_INPUT);
  if (typeof raw === "object") {
    const o = raw as Record<string, unknown>;
    if (typeof o.command === "string") return truncate(o.command, MAX_INPUT);
    if (Array.isArray(o.command)) return truncate(o.command.join(" "), MAX_INPUT);
  }
  try {
    return truncate(JSON.stringify(raw, null, 2), MAX_INPUT);
  } catch {
    return undefined;
  }
}

/**
 * Maps ACP tool-call content into the item. Text, resources and diffs come from
 * `content`; a `terminal` block carries no text (it points at a client-side
 * terminal, which this host does not provide even when an agent sends one), so
 * a command's output comes from `rawOutput` (stdout/stderr, or the agent's
 * formatted output) and only falls back to a placeholder when there is none.
 */
export function applyToolContent(item: ToolItem, content: acp.ToolCallContent[] | undefined, rawInput: unknown, rawOutput: unknown): void {
  const input = stringifyInput(rawInput);
  if (input !== undefined && input !== "{}") item.input = input;
  let terminalOnly = false;
  if (content && content.length > 0) {
    const texts: string[] = [];
    const diffs: { path: string; oldText?: string; newText: string }[] = [];
    for (const c of content) {
      if (c.type === "diff") diffs.push({ path: c.path, ...(c.oldText != null ? { oldText: c.oldText } : {}), newText: c.newText });
      else if (c.type === "content") {
        const b = c.content;
        if (b.type === "text") texts.push(b.text);
        else if (b.type === "resource" && "text" in b.resource) texts.push(String(b.resource.text));
        else if (b.type === "resource_link") texts.push(b.uri);
        else texts.push(`[${b.type}]`);
      } else if (c.type === "terminal") terminalOnly = true;
    }
    if (diffs.length > 0) item.diff = diffs;
    if (texts.length > 0) {
      item.output = truncate(stripFences(texts.join("\n")), MAX_OUTPUT);
      terminalOnly = false;
    }
  }
  if (item.output === undefined || terminalOnly) {
    const out = rawOutputText(rawOutput);
    if (out) item.output = truncate(stripFences(out), MAX_OUTPUT);
  }
}

/** Command output from an agent's `rawOutput`, in whatever shape it uses. */
function rawOutputText(rawOutput: unknown): string | undefined {
  if (rawOutput === undefined || rawOutput === null) return undefined;
  if (typeof rawOutput === "string") return rawOutput;
  if (typeof rawOutput !== "object") return String(rawOutput);
  const o = rawOutput as Record<string, unknown>;
  for (const key of ["formatted_output", "aggregated_output", "output"]) {
    if (typeof o[key] === "string" && o[key]) return o[key] as string;
  }
  if (typeof o.stdout === "string" || typeof o.stderr === "string") {
    const stdout = typeof o.stdout === "string" ? o.stdout : "";
    const stderr = typeof o.stderr === "string" ? o.stderr : "";
    const joined = stdout && stderr ? `${stdout}\n${stderr}` : stdout || stderr;
    if (joined) return joined;
    if (typeof o.exit_code === "number" || typeof o.exitCode === "number") return `exit ${o.exit_code ?? o.exitCode}`;
    return undefined;
  }
  try {
    const json = JSON.stringify(rawOutput, null, 2);
    return json === "{}" ? undefined : json;
  } catch {
    return undefined;
  }
}

/** Agents often wrap tool output in a ``` fence; the UI renders it raw. */
function stripFences(text: string): string {
  const m = /^```[^\n]*\n([\s\S]*?)\n?```\s*$/.exec(text.trim());
  return m ? m[1]! : text;
}

export type { SessionStatus };
