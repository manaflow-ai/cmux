import type { AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  transport: "acpmux-websocket";
  endpoint: string;
  token: string;
  sessionId?: string;
  /** A pane opened as a new chat: do not fall back to the most recent session; the first prompt creates one. */
  newSession?: boolean;
};

export type EventRecord = { sessionId?: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, any> };
type Session = Record<string, any> & { sessionId: string };
type Reply = { id: number; result?: any; error?: { message?: string } };
type Notification = { method: string; params?: any };
type Listener = (snapshot: AcpmuxSnapshot) => void;

export function permissionFromMessage(message: any, selectedSessionId: string): AcpmuxPermission | undefined {
  const envelope = message ?? {};
  const raw = envelope?.request ?? envelope;
  const sessionId = envelope?.sessionId ?? raw?.sessionId;
  const permissionId = envelope?.permissionId ?? raw?.permissionId;
  if (!permissionId || sessionId !== selectedSessionId) return undefined;
  return {
    permissionId: String(permissionId),
    title: raw.toolCall?.title,
    kind: raw.toolCall?.kind,
    pending: true,
    options: (raw.options ?? []).map((option: any) => ({
      id: String(option.optionId ?? option.id),
      name: String(option.name ?? option.optionId),
      allow: String(option.kind ?? "").startsWith("allow"),
    })),
  };
}

export function settleOptimisticPrompt(rows: Map<string, AcpmuxRow>, promptRows: Map<string, string>, message: any): void {
  const promptId = typeof message?.promptId === "string" ? message.promptId : undefined;
  if (!promptId) return;
  const rowId = promptRows.get(promptId);
  if (rowId) rows.delete(rowId);
  promptRows.delete(promptId);
}

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
}

export function applySupersededMessage(rows: Map<string, AcpmuxRow>, messageRows: Map<string, string>, superseded: Set<string>, oldMessageId: string): void {
  superseded.add(oldMessageId);
  const rowId = messageRows.get(oldMessageId);
  if (rowId) rows.delete(rowId);
  messageRows.delete(oldMessageId);
}

/** The session to attach after connect: the selected one, else the most recent unless the pane is a new chat. */
export function initialSession(selected: string | undefined, sessions: { sessionId: string }[], newSession?: boolean): string | undefined {
  if (selected) return selected;
  return newSession ? undefined : sessions[0]?.sessionId;
}

function textFromContent(content: any): string {
  if (typeof content === "string") return content;
  if (content?.type === "text") return String(content.text ?? "");
  if (Array.isArray(content)) return content.map(textFromContent).join("");
  return "";
}

function sessionUpdate(event: EventRecord): any | undefined {
  return event.dir === "in" && event.msg.method === "session/update" ? event.msg.params?.update : undefined;
}

/** Direct browser client for the authenticated acpmux WebSocket protocol. */
export class AcpmuxDirectClient {
  private socket?: WebSocket;
  private nextRequest = 1;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  private events: EventRecord[] = [];
  private rows = new Map<string, AcpmuxRow>();
  private sessions: Session[] = [];
  private selectedSessionId?: string;
  private summary: Record<string, any> | undefined;
  private catalog: any[] = [];
  private queue: { id: string; prompt: string }[] = [];
  private pendingPermission?: AcpmuxPermission;
  private optimisticPromptRows = new Map<string, string>();
  private optimisticPromptTexts = new Map<string, string>();
  private firstSeq?: number;
  private lastSeq = 0;
  private turnOpen = false;
  private streamingAssistant?: string;
  private streamingAssistantMessageId?: string;
  private streamingActivity?: string;
  private supersededMessageIds = new Set<string>();
  private messageRows = new Map<string, string>();
  private readonly listener: Listener;
  private readonly host: AcpmuxHostConfig;
  private reconnectTimer?: number;
  private reconnectDelay = 250;
  /// Called once when an established connection drops. The host then asks Swift
  /// for a fresh handshake, because a restarted daemon has a new port and token.
  private readonly onLost?: () => void;
  private opening = false;
  private hasConnected = false;
  private closed = false;
  private selectionGeneration = 0;
  /// The selection generation whose attach reply has landed; lag resync waits for it.
  private attachedGeneration = -1;
  private historyExhausted = false;

  private constructor(host: AcpmuxHostConfig, listener: Listener, onLost?: () => void) {
    this.host = host;
    this.listener = listener;
    this.onLost = onLost;
    this.selectedSessionId = host.sessionId;
  }

  static async connect(host: AcpmuxHostConfig, listener: Listener, onLost?: () => void): Promise<AcpmuxDirectClient> {
    const client = new AcpmuxDirectClient(host, listener, onLost);
    await client.open();
    return client;
  }

  private async open(): Promise<void> {
    if (this.opening || this.closed) return;
    this.opening = true;
    const url = new URL(this.host.endpoint);
    url.searchParams.set("token", this.host.token);
    await new Promise<void>((resolve, reject) => {
      const socket = new WebSocket(url);
      this.socket = socket;
      let opened = false;
      socket.onopen = () => { opened = true; resolve(); };
      socket.onerror = () => { this.opening = false; reject(new Error("Unable to connect to acpmux WebSocket")); };
      socket.onclose = () => {
        if (this.socket !== socket) return;
        if (!opened) { this.opening = false; reject(new Error("acpmux WebSocket closed before connect")); return; }
        this.rejectPending();
        this.emit("disconnected");
        if (!this.hasConnected || this.closed) return;
        if (this.onLost) { const onLost = this.onLost; this.close(); onLost(); } else this.scheduleReconnect();
      };
      socket.onmessage = (message) => this.receive(String(message.data));
    });
    try {
      await this.request("initialize", { protocolVersion: 1, clientInfo: { name: "cmux-react-agent-pane", version: "1" }, clientCapabilities: {} });
      const watched = await this.request("_acpmux/watch", { enabled: true });
      this.sessions = (watched?.sessions ?? []).filter((session: Session) => session.sessionId);
      const harnesses = await this.request("_acpmux/harnesses", {});
      this.catalog = normalizeCatalog(harnesses);
      if (this.selectedSessionId && !this.sessions.some((session) => session.sessionId === this.selectedSessionId)) {
        this.selectedSessionId = this.sessions[0]?.sessionId;
        this.selectionGeneration += 1;
        this.resetSessionState();
      }
      this.selectedSessionId = initialSession(this.selectedSessionId, this.sessions, this.host.newSession);
      // A reconnect to the same session keeps its transcript; the attach page holds only the newest events.
      const resumeAfter = this.lastSeq;
      const sessionId = this.selectedSessionId;
      const generation = this.selectionGeneration;
      if (sessionId) {
        const page = await this.attach(sessionId, generation);
        const oldest = page.length > 0 ? Math.min(...page.map((event) => event.seq)) : 0;
        if (resumeAfter > 0 && oldest > resumeAfter + 1) await this.fetchMissedEvents(sessionId, generation, resumeAfter, false);
      }
      this.hasConnected = true;
      this.reconnectDelay = 250;
      this.emit("connected");
    } catch (error) {
      this.socket?.close();
      throw error;
    } finally {
      this.opening = false;
    }
  }

  /** Drops everything that belongs to the previously selected session, before another one attaches. */
  private resetSessionState(): void {
    this.events = [];
    this.historyExhausted = false;
    this.rows.clear();
    this.firstSeq = undefined;
    this.lastSeq = 0;
    this.summary = undefined;
    this.queue = [];
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.optimisticPromptRows.clear();
    this.optimisticPromptTexts.clear();
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.pendingPermission = undefined;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined || this.closed) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(delay * 2, 30_000);
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.open().catch(() => this.scheduleReconnect());
    }, delay);
  }

  private receive(raw: string): void {
    let message: Reply | Notification;
    try { message = JSON.parse(raw) as Reply | Notification; } catch { return; }
    if ("id" in message && typeof message.id === "number") {
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message ?? "acpmux request failed"));
      else request.resolve(message.result);
      return;
    }
    const notification = message as Notification;
    if (notification.method === "_acpmux/event") this.apply(notification.params as EventRecord);
    else if (notification.method === "session/update") this.apply({
      sessionId: notification.params?.sessionId,
      seq: Number(notification.params?._meta?.acpmux?.seq ?? 0),
      at: Number(notification.params?._meta?.acpmux?.at ?? Date.now()),
      dir: "in",
      kind: String(notification.params?.update?.sessionUpdate ?? ""),
      msg: { method: "session/update", params: { update: notification.params?.update } },
    });
    else if (notification.method === "_acpmux/session_changed") this.sessionChanged(notification.params);
    else if (notification.method === "_acpmux/permission_pending") this.applyPermission(notification.params);
    else if (notification.method === "_acpmux/lagged") this.resyncAfterLag(notification.params);
  }

  /// The daemon dropped events for this client. Fetch what came after the last
  /// one seen and merge it in, keeping the transcript on screen meanwhile.
  /// agent-gui daemons send {sessionIds, watch, dropped}; older ones send only
  /// {dropped}, so a notice without sessionIds resyncs the selected session.
  private resyncAfterLag(params: any): void {
    if (params?.watch === true) void this.refreshSessions().catch(() => undefined);
    const sessionId = this.selectedSessionId;
    // Before the attach reply lands there is no cursor; the reply carries the latest events.
    if (!sessionId || this.attachedGeneration !== this.selectionGeneration) return;
    if (Array.isArray(params?.sessionIds) && !params.sessionIds.map(String).includes(sessionId)) return;
    this.emit("resyncing");
    const generation = this.selectionGeneration;
    void this.fetchMissedEvents(sessionId, generation, this.lastSeq).catch(() => {
      if (!this.closed && generation === this.selectionGeneration) this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
    });
  }

  /// Pages from its own cursor: live events keep advancing lastSeq meanwhile.
  /// The live summary, queue and permission survive the rebuild; after a lag the
  /// missed events are replayed onto them, while a fresh attach is already current.
  private async fetchMissedEvents(sessionId: string, generation: number, afterSeq: number, replayLiveState = true): Promise<void> {
    for (let cursor = afterSeq; ;) {
      const result = await this.request("_acpmux/events", { sessionId, afterSeq: cursor, limit: 5_000 });
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      const missed: EventRecord[] = result?.events ?? [];
      this.events = mergeEventRecords(this.events, missed);
      this.rebuildKeepingLiveState(replayLiveState ? cursor : undefined);
      if (result?.more !== true || missed.length === 0) break;
      cursor = Math.max(cursor, ...missed.map((event) => event.seq));
    }
    this.emit("resynced");
  }

  /// session_changed notices dropped by a watch lag: reread the whole list.
  /// A selection made while the request was out is newer than the list.
  private async refreshSessions(): Promise<void> {
    const generation = this.selectionGeneration;
    const watched = await this.request("_acpmux/watch", { enabled: true });
    this.sessions = (watched?.sessions ?? []).filter((session: Session) => session.sessionId);
    const missing = this.selectedSessionId !== undefined && !this.sessions.some((session) => session.sessionId === this.selectedSessionId);
    if (missing && generation === this.selectionGeneration) this.selectFallbackSession("session changed");
    else this.emit("session changed");
  }

  /// The selected session is gone: show the most recent remaining one, or none.
  private selectFallbackSession(reason: string): void {
    this.selectedSessionId = this.sessions[0]?.sessionId;
    const generation = ++this.selectionGeneration;
    this.resetSessionState();
    this.emit(reason);
    if (this.selectedSessionId) void this.attach(this.selectedSessionId, generation).catch(() => undefined);
  }

  private request(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.socket?.readyState !== WebSocket.OPEN) return Promise.reject(new Error("acpmux WebSocket is not open"));
    const id = this.nextRequest++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket!.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  /// Returns the attach page's events, or none when the selection moved on.
  private async attach(sessionId: string, generation = this.selectionGeneration): Promise<EventRecord[]> {
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const result = await this.request("_acpmux/attach", { sessionId, limit: 400, kinds: ["transcript"], eventStream: true });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const page: EventRecord[] = result?.events ?? [];
    const detail = result?.session ?? {};
    this.summary = detail;
    this.queue = (detail.queue ?? []).map((entry: any) => ({ id: String(entry.promptId), prompt: String(entry.prompt ?? "") }));
    this.events = mergeEventRecords(page, this.events);
    this.rebuild();
    this.attachedGeneration = generation;
    this.emit("attached");
    return page;
  }

  private sessionChanged(params: any): void {
    const session = params?.session;
    if (params?.kind === "purged" && session?.sessionId) {
      this.sessions = this.sessions.filter((item) => item.sessionId !== session.sessionId);
      if (session.sessionId === this.selectedSessionId) this.selectFallbackSession("session purged");
      else this.emit("session purged");
      return;
    }
    if (!session?.sessionId) return;
    this.sessions = [...this.sessions.filter((item) => item.sessionId !== session.sessionId), session];
    if (session.sessionId === this.selectedSessionId) {
      this.summary = { ...this.summary, ...session };
      this.queue = (session.queue ?? this.queue).map((entry: any) => ({ id: String(entry.promptId), prompt: String(entry.prompt ?? entry.preview ?? "") }));
    }
    // The picker lists every session, so a change elsewhere still needs a snapshot.
    this.emit("session changed");
  }

  private applyPermission(message: any): void {
    const permission = permissionFromMessage(message, this.selectedSessionId ?? "");
    if (!permission) return;
    this.pendingPermission = permission;
    this.emit("permission");
  }

  private apply(event: EventRecord): void {
    if (!event?.seq || event.sessionId !== this.selectedSessionId || event.seq <= this.lastSeq) return;
    this.events.push(event);
    this.lastSeq = event.seq;
    this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
    this.reduce(event);
    this.emit(event.kind);
  }

  private rebuild(): void {
    // A prompt still in flight keeps its optimistic row until an event settles it; a failed one stays to show it was not sent.
    const inFlight = new Set(this.optimisticPromptRows.values());
    const local = [...this.rows.values()].filter((row) => row.failed || inFlight.has(row.id));
    this.rows.clear(); for (const row of local) this.rows.set(row.id, row); this.firstSeq = undefined; this.lastSeq = 0; this.turnOpen = false; this.streamingAssistant = undefined; this.streamingAssistantMessageId = undefined; this.streamingActivity = undefined; this.supersededMessageIds.clear(); this.messageRows.clear(); this.pendingPermission = undefined;
    const events = [...this.events].sort((a, b) => a.seq - b.seq);
    for (const event of events) { this.lastSeq = Math.max(this.lastSeq, event.seq); this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq); this.reduce(event); }
  }

  /// rebuild() replays a partial event window, so keep the live summary, queue and
  /// permission; events after replayAfterSeq are then reapplied on top of them.
  private rebuildKeepingLiveState(replayAfterSeq?: number): void {
    const summary = this.summary;
    const queue = this.queue;
    const permission = this.pendingPermission;
    this.rebuild();
    this.summary = summary;
    this.queue = queue;
    this.pendingPermission = permission;
    if (replayAfterSeq !== undefined) for (const event of this.events) if (event.seq > replayAfterSeq && event.dir === "mux") this.reduceLiveState(event);
  }

  /// Mux events that move the live summary, queue or permission.
  private reduceLiveState(event: EventRecord): void {
    const msg = event.msg ?? {};
    if (event.kind === "queued" || event.kind === "queue_updated") { const id = String(msg.promptId ?? ""); if (id) this.queue = [...this.queue.filter((entry) => entry.id !== id), { id, prompt: String(msg.text ?? "") }]; }
    else if (event.kind === "queue_removed" || event.kind === "dequeued") this.queue = this.queue.filter((entry) => entry.id !== String(msg.promptId ?? ""));
    else if (event.kind === "permission_request") this.applyPermission({ ...msg, sessionId: event.sessionId });
    else if (event.kind === "permission_decision") this.pendingPermission = undefined;
    else if (event.kind === "status") this.summary = { ...this.summary, status: msg.status };
  }

  private reduce(event: EventRecord): void {
    const msg = event.msg ?? {};
    const update = sessionUpdate(event);
    if (event.dir === "mux") {
      if (event.kind === "user_message") {
        const promptId = typeof msg.promptId === "string" ? msg.promptId : undefined;
        const text = typeof msg.text === "string" ? msg.text : undefined;
        const fallbackPromptId = promptId ?? (text ? [...this.optimisticPromptTexts.entries()].find(([, value]) => value === text)?.[0] : undefined);
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, { ...msg, promptId: fallbackPromptId });
        if (fallbackPromptId) this.optimisticPromptTexts.delete(fallbackPromptId);
        this.rows.set(`user-${event.seq}`, { id: `user-${event.seq}`, version: 1, at: event.at, kind: "user", text: String(msg.text ?? "") }); this.turnOpen = true;
      }
      else if (event.kind === "turn_started") { this.turnOpen = true; this.rows.set("typing", { id: "typing", version: 1, at: event.at, kind: "typing" }); }
      else if (event.kind === "message_superseded") {
        const oldMessageId = typeof msg.oldMessageId === "string" ? msg.oldMessageId : undefined;
        if (oldMessageId) {
          applySupersededMessage(this.rows, this.messageRows, this.supersededMessageIds, oldMessageId);
          if (this.streamingAssistantMessageId === oldMessageId) { this.streamingAssistant = undefined; this.streamingAssistantMessageId = undefined; }
        }
      }
      else if (event.kind === "turn_end" || event.kind === "turn_result") { this.turnOpen = false; if (this.streamingAssistant) { const row = this.rows.get(this.streamingAssistant); if (row) { row.streaming = false; row.version += 1; } } this.rows.delete("typing"); if (event.kind === "turn_result") this.rows.set(`summary-${event.seq}`, { id: `summary-${event.seq}`, version: 1, at: event.at, kind: "turnSummary", durationMs: undefined, toolCount: [...this.rows.values()].filter((row) => row.kind === "activity").length, status: String(msg.status ?? "completed"), error: msg.errorText }); this.streamingAssistant = undefined; this.streamingAssistantMessageId = undefined; this.streamingActivity = undefined; }
      else this.reduceLiveState(event);
      return;
    }
    if (!update) return;
    const text = textFromContent(update.content);
    if (event.kind === "agent_message_chunk" && text) {
      const messageId = typeof update.messageId === "string" ? update.messageId : undefined;
      if (messageId && this.supersededMessageIds.has(messageId)) return;
      const sameMessage = Boolean(this.streamingAssistant && (!messageId || !this.streamingAssistantMessageId || this.streamingAssistantMessageId === messageId));
      const id = sameMessage ? this.streamingAssistant! : `assistant-${event.seq}`;
      const existing = this.rows.get(id);
      this.rows.set(id, { id, version: (existing?.version ?? 0) + 1, at: event.at, kind: "assistant", text: `${existing?.text ?? ""}${text}`, streaming: true }); this.streamingAssistant = id; this.streamingAssistantMessageId = messageId; if (messageId) this.messageRows.set(messageId, id); this.rows.delete("typing");
    } else if (event.kind === "agent_thought_chunk" && text) {
      const id = this.streamingActivity ?? `activity-${event.seq}`; const existing = this.rows.get(id);
      this.rows.set(id, { id, version: (existing?.version ?? 0) + 1, at: event.at, kind: "activity", toolCount: existing?.toolCount ?? 0, items: [...(existing?.items ?? []), { kind: "thought", text }] }); this.streamingActivity = id;
    } else if (event.kind === "tool_call" || event.kind === "tool_call_update") {
      const callId = String(update.toolCallId ?? `tool-${event.seq}`); const id = this.streamingActivity ?? `activity-${event.seq}`; const existing = this.rows.get(id); const items = [...(existing?.items ?? [])]; const itemIndex = items.findIndex((item) => item.tool?.id === callId); const item = { kind: "tool", text: String(update.title ?? update.name ?? callId), tool: { id: callId, title: String(update.title ?? callId), kind: update.kind, status: String(update.status ?? "in_progress"), inputSummary: update.rawInput ? JSON.stringify(update.rawInput) : undefined, output: text || undefined } };
      if (itemIndex >= 0) items[itemIndex] = item; else items.push(item);
      this.rows.set(id, { id, version: (existing?.version ?? 0) + 1, at: event.at, kind: "activity", toolCount: items.filter((entry) => entry.kind === "tool").length, items }); this.streamingActivity = id;
    } else if (event.kind === "plan") this.rows.set(`plan-${event.seq}`, { id: `plan-${event.seq}`, version: 1, at: event.at, kind: "plan", text: text || JSON.stringify(update.entries ?? update.content ?? "") });
  }

  private emit(connection = "connected"): void {
    const summary = this.summary;
    const effort = (summary?.configOptions ?? []).find((option: any) => option.category === "thought_level" || option.id === "reasoning_effort");
    this.listener({ type: "snapshot", protocolVersion: 1, rows: [...this.rows.values()].sort((a, b) => a.at - b.at), sessions: this.sessions.map((session) => ({ sessionId: session.sessionId, displayTitle: session.title ?? session.name, title: session.title, name: session.name, status: session.status, model: session.model })), summary: summary ? { sessionId: summary.sessionId, title: summary.title, name: summary.name, harness: summary.harness, model: summary.model, effort: effort?.currentValue, status: summary.status, modes: summary.modes, configOptions: summary.configOptions } : undefined, connection, sessionId: this.selectedSessionId, isWorking: this.turnOpen || summary?.status === "running", queue: this.queue, permission: this.pendingPermission, catalog: this.catalog, canLoadOlder: !this.historyExhausted && (this.firstSeq ?? 1) > 1 });
  }

  snapshot(): void { this.emit(); }
  async ensureSession(): Promise<string | undefined> {
    if (!this.selectedSessionId) await this.create();
    return this.selectedSessionId;
  }
  async send(text: string): Promise<string | undefined> {
    const sessionId = await this.ensureSession();
    if (!sessionId) return undefined;
    const promptId = crypto.randomUUID(); const rowId = `local-${promptId}`; const at = Date.now();
    this.optimisticPromptRows.set(promptId, rowId); this.optimisticPromptTexts.set(promptId, text);
    this.rows.set(rowId, { id: rowId, version: 1, at, kind: "user", text, pending: true }); this.emit();
    try {
      await this.request("session/prompt", { sessionId, prompt: [{ type: "text", text }], _meta: { acpmux: { promptId } } });
    } catch (error) {
      const row = this.rows.get(rowId);
      if (row) { row.pending = false; row.failed = true; row.version += 1; }
      this.optimisticPromptRows.delete(promptId); this.optimisticPromptTexts.delete(promptId); this.emit("failed");
      throw error;
    }
    return sessionId;
  }
  async cancel(): Promise<void> { if (this.selectedSessionId) this.socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: this.selectedSessionId } })); }
  async permission(permissionId: string, optionId: string): Promise<void> { if (this.selectedSessionId) await this.request("_acpmux/permission_respond", { sessionId: this.selectedSessionId, permissionId, optionId }); }
  async select(sessionId: string): Promise<string | undefined> {
    const previousSessionId = this.selectedSessionId;
    const generation = ++this.selectionGeneration;
    this.selectedSessionId = sessionId;
    this.resetSessionState();
    if (previousSessionId && previousSessionId !== sessionId) {
      // Detach is cleanup for the old selection. A stale daemon or a dropped
      // socket must not prevent the requested session from attaching.
      try {
        await this.request("_acpmux/detach", { sessionId: previousSessionId });
      } catch {
        // The selection generation still guards the attach below.
      }
    }
    await this.attach(sessionId, generation);
    return generation === this.selectionGeneration && this.selectedSessionId === sessionId ? sessionId : undefined;
  }
  async create(harness?: string): Promise<string | undefined> { const result = await this.request("session/new", { mcpServers: [], _meta: { acpmux: { harness } } }); if (result?.sessionId) return this.select(String(result.sessionId)); return undefined; }
  async setModel(modelId: string): Promise<void> { if (this.selectedSessionId) await this.request("session/set_model", { sessionId: this.selectedSessionId, modelId }); }
  async setMode(modeId: string): Promise<void> { if (this.selectedSessionId) await this.request("session/set_mode", { sessionId: this.selectedSessionId, modeId }); }
  async setConfig(configId: string, value: string): Promise<void> { if (this.selectedSessionId) await this.request("session/set_config_option", { sessionId: this.selectedSessionId, configId, value }); }
  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  async loadOlder(): Promise<void> {
    if (!this.selectedSessionId || !this.firstSeq || this.firstSeq <= 1 || this.historyExhausted) return;
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const result = await this.request("_acpmux/events", { sessionId, beforeSeq: this.firstSeq, limit: 400, kinds: ["transcript"] });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
    const older: EventRecord[] = result?.events ?? [];
    this.events = mergeEventRecords(older, this.events);
    this.rebuildKeepingLiveState();
    this.historyExhausted = result?.more === false || older.length === 0 || (this.firstSeq ?? 1) <= 1;
    this.emit("history");
  }
  /// The socket's own onclose ignores a socket close() already let go of, so settle requests here.
  close(): void { this.closed = true; if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer); this.reconnectTimer = undefined; this.socket?.close(); this.socket = undefined; this.rejectPending(); }
  private rejectPending(): void { for (const request of this.pending.values()) request.reject(new Error("acpmux WebSocket closed")); this.pending.clear(); }
}

function normalizeCatalog(value: any): any[] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  return (Array.isArray(harnesses) ? harnesses : Object.entries(harnesses).map(([id, data]) => ({ id, ...(data as any) }))).map((harness: any) => ({ id: String(harness.id ?? harness.name), name: String(harness.name ?? harness.id), models: (harness.models ?? []).map((model: any) => ({ id: String(model.id ?? model.modelId), name: model.name })) }));
}
