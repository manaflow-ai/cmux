export type DashboardDeviceRecord = {
  readonly deviceRecordId: string;
  readonly descriptor: {
    readonly identity: { readonly deviceId: string };
    readonly metadata: { readonly displayName: string; readonly platform: string; readonly appVersion: string };
  };
  readonly revision: number;
  readonly revoked: boolean;
};

export type DashboardDirectory = {
  readonly teamId: string;
  readonly revision: number;
  readonly devices: readonly DashboardDeviceRecord[];
  readonly relayURLs: readonly string[];
  readonly issuedAt: number;
  readonly nextCursor: string | null;
  readonly canManageTeam: boolean;
  readonly managedDeviceIds: readonly string[];
};

export type DashboardWorkspace = {
  readonly vmId: string;
  readonly generation: string;
  readonly revision: number;
  readonly snapshot: {
    readonly workspaces: readonly { readonly id: string; readonly name: string; readonly index: number; readonly focused: boolean }[];
    readonly terminals: readonly { readonly id: string; readonly title: string; readonly workspaceId: string | null; readonly cwd: string | null; readonly agent: string | null }[];
  };
};
type DashboardWorkspaceSummary = Pick<DashboardWorkspace, "vmId" | "generation" | "revision">;

type DashboardOptions = {
  readonly origin: string;
  readonly environment: string;
  readonly projectId: string;
  readonly userId: string;
  readonly teamId: string;
  readonly getStackToken: () => Promise<string | null>;
  readonly onDirectory: (directory: DashboardDirectory) => void;
  readonly onWorkspaces?: (workspaces: readonly DashboardWorkspace[]) => void;
  readonly onError: (message: string) => void;
};

type Ticket = { readonly token: string; readonly expiresAt: number; readonly refreshAfter: number };
type Connected = { readonly schemaId: "dashboard.connected.v1"; readonly teamRevision: number; readonly expiresAt: number };
type ErrorResponse = { readonly schemaId: "error.v1"; readonly code: string; readonly retryable: boolean; readonly retryAfterMs?: number };
type Frame = { readonly schemaId?: string; readonly requestId?: string; readonly response?: unknown; readonly directory?: DashboardDirectory; readonly revision?: number; readonly deliveryReceipt?: { readonly sequence: number; readonly token: string } } & Record<string, unknown>;

const REQUEST_TIMEOUT_MS = 10_000;
// Only the three managed Workers may receive browser Stack tokens. A generic
// workers.dev suffix would also trust another account's Worker.
const ORIGIN_ALLOWED = /^https:\/\/cmux-iroh-v2(?:-development|-staging)?\.cmux-presence-worker\.workers\.dev$/u;

export class V2DashboardController {
  private readonly options: DashboardOptions;
  private readonly clientInstanceId: string;
  private socket: WebSocket | null = null;
  private stopped = false;
  private revision: number | undefined;
  private ticket: Ticket | null = null;
  private refreshTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelayMs = 1_000;
  private requestCounter = 0;
  private pending = new Map<string, { resolve: (frame: Frame) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();

  constructor(options: DashboardOptions) {
    if (!ORIGIN_ALLOWED.test(options.origin)) throw new Error("IROH Dashboard origin is not an approved Cloudflare Worker");
    this.options = options;
    const storageKey = "cmux-iroh-v2.dashboard.client-instance";
    const storage = typeof sessionStorage === "undefined" ? null : sessionStorage;
    const existing = storage?.getItem(storageKey) ?? null;
    this.clientInstanceId = existing ?? crypto.randomUUID();
    if (!existing) storage?.setItem(storageKey, this.clientInstanceId);
  }

  async start(): Promise<void> {
    try {
      this.ticket = await this.openSession();
      await this.connect(this.ticket);
      this.scheduleRefresh();
    } catch (cause) { this.fail(cause); }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error("Dashboard session stopped")); }
    this.pending.clear();
    this.socket?.close(1000, "dashboard_stop");
    this.socket = null;
  }

  async revoke(deviceRecordId: string): Promise<void> {
    const requestId = this.nextRequestId();
    const frame = await this.request({ schemaId: "device.revoke.v1", requestId, deviceRecordId });
    this.expectSuccess(frame, requestId);
    await this.requestDirectory();
  }

  async updateRelayPreferences(relayURLs: string[]): Promise<void> {
    if (this.revision === undefined) throw new Error("Dashboard directory is not ready");
    const requestId = this.nextRequestId();
    const frame = await this.request({ schemaId: "preferences.update.v1", requestId, relayURLs, expectedRevision: this.revision });
    this.expectSuccess(frame, requestId);
    await this.requestDirectory();
  }

  private async openSession(): Promise<Ticket> {
    const stackToken = await this.options.getStackToken();
    if (!stackToken) throw new Error("Dashboard sign-in expired");
    const requestId = this.nextRequestId();
    const response = await fetch(`${this.options.origin}/v2/dashboard/session`, {
      method: "POST", mode: "cors", credentials: "omit",
      headers: { authorization: `Bearer ${stackToken}`, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ schemaId: "dashboard.open.v1", requestId, clientInstanceId: this.clientInstanceId, environment: this.options.environment, projectId: this.options.projectId, teamId: this.options.teamId, userId: this.options.userId }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    const body = await this.readJSON(response) as Record<string, unknown>;
    if (!response.ok || body.schemaId !== "dashboard.ready.v1") throw this.errorFrom(body);
    if (!isTicket(body.ticket)) throw new Error("Dashboard session returned an invalid ticket");
    return body.ticket;
  }

  private async connect(ticket: Ticket): Promise<void> {
    const previous = this.socket;
    const socket = new WebSocket(`${this.options.origin}/v2/dashboard/socket`, ["cmux-v2-dashboard", `ticket.${ticket.token}`]);
    this.socket = socket;
    try {
      await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { socket.close(); reject(new Error("Dashboard socket timed out")); }, REQUEST_TIMEOUT_MS);
      socket.onopen = () => undefined;
      let connected = false;
      socket.onmessage = event => {
        const frame = parseFrame(event.data);
        if (!frame) return;
        if (frame.deliveryReceipt && Number.isSafeInteger(frame.deliveryReceipt.sequence) && typeof frame.deliveryReceipt.token === "string") {
          socket.send(JSON.stringify({ schemaId: "session.ack.v1", requestId: this.nextRequestId(), sequence: frame.deliveryReceipt.sequence, token: frame.deliveryReceipt.token }));
        }
        if (frame.schemaId === "dashboard.connected.v1") {
          connected = true;
          this.reconnectDelayMs = 1_000;
          clearTimeout(timeout);
          resolve();
          void this.requestDirectory()
            .then(() => this.options.onWorkspaces ? this.requestWorkspaces() : undefined)
            .catch(cause => this.fail(cause));
          return;
        }
        this.resolvePending(frame);
        if (frame.schemaId === "directory.changed.v1" && typeof frame.revision === "number" && frame.revision > (this.revision ?? -1)) {
          void this.requestDirectory().catch(cause => this.fail(cause));
        }
        if (frame.schemaId === "workspace.changed.v1" && this.options.onWorkspaces) {
          void this.requestWorkspaces().catch(cause => this.fail(cause));
        }
      };
      socket.onerror = () => { clearTimeout(timeout); reject(new Error("Dashboard socket failed")); };
      socket.onclose = event => {
        clearTimeout(timeout);
        if (this.stopped || this.socket !== socket) return;
        if (!connected) reject(new Error(`Dashboard socket closed (${event.code})`));
        else this.scheduleReconnect();
      };
      });
    } catch (error) {
      if (this.socket === socket) this.socket = previous;
      throw error;
    }
    // Retire the old connection only after the replacement emitted its
    // connected frame. This keeps in-flight directory/mutation requests live.
    if (previous && previous !== socket) previous.close(1000, "dashboard_replaced");
  }

  private async requestDirectory(cursor: string | null = null, seenCursors = new Set<string>()): Promise<void> {
    if (cursor) {
      if (seenCursors.has(cursor)) throw new Error("Dashboard directory cursor repeated");
      seenCursors.add(cursor);
    }
    const requestId = this.nextRequestId();
    let frame: Frame;
    try {
      frame = await this.request({ schemaId: "directory.request.v1", requestId, ...(this.revision === undefined ? {} : { haveRevision: this.revision }), ...(cursor ? { cursor } : {}) });
    } catch (cause) {
      if (errorCode(cause) === "resync_required") {
        this.revision = undefined;
        return this.requestDirectory(null, seenCursors);
      }
      throw cause;
    }
    if (frame.schemaId !== "dashboard.directory.v1" || !isDirectory(frame.directory)) throw new Error("Dashboard returned an invalid directory");
    if (frame.directory.revision < (this.revision ?? -1)) return;
    this.revision = frame.directory.revision;
    this.options.onDirectory(frame.directory);
    if (frame.directory.nextCursor) await this.requestDirectory(frame.directory.nextCursor, seenCursors);
  }

  private async requestWorkspaces(): Promise<void> {
    const requestId = this.nextRequestId();
    const frame = await this.request({ schemaId: "workspace.list.v1", requestId });
    if (frame.schemaId !== "workspace.list.result.v1" || !isWorkspaceList(frame.workspaces)) {
      throw new Error("Dashboard returned an invalid workspace list");
    }
    const snapshots = await Promise.all(frame.workspaces.map(item => this.requestWorkspace(item.vmId)));
    this.options.onWorkspaces?.(snapshots);
  }

  private async requestWorkspace(vmId: string): Promise<DashboardWorkspace> {
    const requestId = this.nextRequestId();
    const frame = await this.request({ schemaId: "workspace.get.v1", requestId, vmId });
    if (frame.schemaId !== "workspace.snapshot.result.v1" || !isWorkspaceSnapshot(frame)) {
      throw new Error("Dashboard returned an invalid workspace snapshot");
    }
    return frame;
  }

  private request(input: Record<string, unknown>): Promise<Frame> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return Promise.reject(new Error("Dashboard socket is not ready"));
    const requestId = String(input.requestId ?? this.nextRequestId());
    const payload = JSON.stringify(input);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(requestId); reject(new Error("Dashboard request timed out")); }, REQUEST_TIMEOUT_MS);
      this.pending.set(requestId, { resolve, reject, timer });
      this.socket?.send(payload);
    });
  }

  private resolvePending(frame: Frame) {
    const requestId = typeof frame.requestId === "string" ? frame.requestId : null;
    if (!requestId) return;
    const pending = this.pending.get(requestId); if (!pending) return;
    this.pending.delete(requestId); clearTimeout(pending.timer);
    if (frame.schemaId === "error.v1") pending.reject(this.errorFrom(frame)); else pending.resolve(frame);
  }

  private scheduleRefresh() {
    const delay = Math.max(10_000, ((this.ticket?.refreshAfter ?? 0) * 1000) - Date.now());
    this.refreshTimer = setTimeout(() => { void this.refreshTicketMakeBeforeBreak(); }, delay);
  }

  private scheduleReconnect() {
    if (this.stopped || this.reconnectTimer) return;
    const delay = this.reconnectDelayMs;
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, 60_000);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.reconnect().catch(cause => this.fail(cause));
    }, delay);
  }

  private async reconnect() {
    if (this.stopped) return;
    try {
      const replacement = await this.openSession();
      await this.connect(replacement);
      this.ticket = replacement;
      this.scheduleRefresh();
    } catch (cause) {
      this.fail(cause);
      this.scheduleReconnect();
    }
  }

  private async refreshTicketMakeBeforeBreak() {
    if (this.stopped) return;
    try {
      const replacement = await this.openSession();
      await this.connect(replacement);
      this.ticket = replacement;
      this.scheduleRefresh();
    }
    catch (cause) { this.fail(cause); this.refreshTimer = setTimeout(() => void this.refreshTicketMakeBeforeBreak(), 60_000); }
  }

  private fail(cause: unknown) { this.options.onError(cause instanceof Error ? cause.message : "Dashboard request failed"); }
  private nextRequestId() { this.requestCounter += 1; return `${this.clientInstanceId}:${this.requestCounter}`; }
  private expectSuccess(frame: Frame, requestId: string) { if (frame.requestId !== requestId || frame.schemaId === "error.v1") throw this.errorFrom(frame); }
  private errorFrom(body: unknown): Error {
    const error = body as Partial<ErrorResponse>;
    const result = new Error(error.code === "permission_denied" ? "You do not have permission to change this device" : error.code === "team_access_revoked" ? "Team access was removed" : `Dashboard request failed (${error.code ?? "unknown"})`);
    if (typeof error.code === "string") Object.assign(result, { code: error.code });
    return result;
  }
  private async readJSON(response: Response): Promise<unknown> { try { return await response.json(); } catch { throw new Error(`Dashboard returned HTTP ${response.status}`); } }
}

function parseFrame(value: unknown): Frame | null { try { const parsed = typeof value === "string" ? JSON.parse(value) : value; return parsed && typeof parsed === "object" ? parsed as Frame : null; } catch { return null; } }
function isTicket(value: unknown): value is Ticket { return !!value && typeof value === "object" && typeof (value as Ticket).token === "string" && typeof (value as Ticket).expiresAt === "number" && typeof (value as Ticket).refreshAfter === "number"; }
function isDirectory(value: unknown): value is DashboardDirectory { if (!value || typeof value !== "object") return false; const candidate = value as DashboardDirectory; return typeof candidate.teamId === "string" && Number.isSafeInteger(candidate.revision) && Array.isArray(candidate.devices) && Array.isArray(candidate.relayURLs) && typeof candidate.canManageTeam === "boolean" && Array.isArray(candidate.managedDeviceIds); }
function isWorkspaceList(value: unknown): value is readonly DashboardWorkspaceSummary[] {
  if (!Array.isArray(value)) return false;
  return value.every(item => {
    if (!item || typeof item !== "object") return false;
    const candidate = item as DashboardWorkspace;
    return typeof candidate.vmId === "string" && typeof candidate.generation === "string" && Number.isSafeInteger(candidate.revision);
  });
}
function isWorkspaceSnapshot(value: Record<string, unknown>): value is DashboardWorkspace {
  return typeof value.vmId === "string" && typeof value.generation === "string" && Number.isSafeInteger(value.revision)
    && !!value.snapshot && typeof value.snapshot === "object"
    && Array.isArray((value.snapshot as DashboardWorkspace["snapshot"]).workspaces)
    && Array.isArray((value.snapshot as DashboardWorkspace["snapshot"]).terminals);
}
function errorCode(value: unknown): string | undefined { return value instanceof Error && typeof (value as Error & { code?: unknown }).code === "string" ? (value as Error & { code: string }).code : undefined; }
