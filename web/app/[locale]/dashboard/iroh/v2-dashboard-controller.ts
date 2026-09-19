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

type DashboardOptions = {
  readonly origin: string;
  readonly environment: string;
  readonly projectId: string;
  readonly userId: string;
  readonly teamId: string;
  readonly getStackToken: () => Promise<string | null>;
  readonly onDirectory: (directory: DashboardDirectory) => void;
  readonly onError: (message: string) => void;
  readonly retryClock?: DashboardRetryClock;
};

type Ticket = { readonly token: string; readonly expiresAt: number; readonly refreshAfter: number };
type ErrorResponse = { readonly schemaId: "error.v1"; readonly code: string; readonly retryable: boolean; readonly retryAfterMs?: number };
type Frame = { readonly schemaId?: string; readonly requestId?: string; readonly response?: unknown; readonly directory?: DashboardDirectory; readonly revision?: number; readonly deliveryReceipt?: { readonly sequence: number; readonly token: string } } & Record<string, unknown>;

const REQUEST_TIMEOUT_MS = 10_000;
// Only the three managed Workers may receive browser Stack tokens. A generic
// workers.dev suffix would also trust another account's Worker.
const ORIGIN_ALLOWED = /^https:\/\/cmux-iroh-v2(?:-development|-staging)?\.debussy\.workers\.dev$/u;

export class V2DashboardController {
  private readonly options: DashboardOptions;
  private readonly clientInstanceId: string;
  private socket: WebSocket | null = null;
  private stopped = false;
  private connectionAttempt: Promise<void> | null = null;
  private revision: number | undefined;
  private ticket: Ticket | null = null;
  private readonly retries: DashboardRetryScheduler;
  private reconnectDelayMs = 1_000;
  private requestCounter = 0;
  private pending = new Map<string, { resolve: (frame: Frame) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();

  constructor(options: DashboardOptions) {
    if (!ORIGIN_ALLOWED.test(options.origin)) throw new Error("IROH Dashboard origin is not an approved Cloudflare Worker");
    this.options = options;
    this.retries = new DashboardRetryScheduler(options.retryClock);
    const storageKey = "cmux-iroh-v2.dashboard.client-instance";
    const storage = typeof sessionStorage === "undefined" ? null : sessionStorage;
    const existing = storage?.getItem(storageKey) ?? null;
    this.clientInstanceId = existing ?? crypto.randomUUID();
    if (!existing) storage?.setItem(storageKey, this.clientInstanceId);
  }

  async start(): Promise<void> {
    await this.reconnect();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.retries.stop();
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
    if (this.stopped) return;
    const previous = this.socket;
    const socket = new WebSocket(`${this.options.origin}/v2/dashboard/socket`, ["cmux-v2-dashboard", `ticket.${ticket.token}`]);
    this.socket = socket;
    try {
      await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { socket.close(); reject(new Error("Dashboard socket timed out")); }, REQUEST_TIMEOUT_MS);
      socket.onopen = () => undefined;
      let connected = false;
      socket.onmessage = event => {
        if (this.stopped || this.socket !== socket) return;
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
          void this.requestDirectory().catch(cause => this.fail(cause));
          return;
        }
        this.resolvePending(frame);
        if (frame.schemaId === "directory.changed.v1" && typeof frame.revision === "number" && frame.revision > (this.revision ?? -1)) {
          void this.requestDirectory().catch(cause => this.fail(cause));
        }
      };
      socket.onerror = () => { clearTimeout(timeout); reject(new Error("Dashboard socket failed")); };
      socket.onclose = event => {
        clearTimeout(timeout);
        if (!connected) reject(new Error(`Dashboard socket closed (${event.code})`));
        if (this.stopped || this.socket !== socket) return;
        if (connected) this.scheduleReconnect();
      };
      });
    } catch (error) {
      if (this.socket === socket) this.socket = previous;
      socket.close();
      throw error;
    }
    // Retire the old connection only after the replacement emitted its
    // connected frame. This keeps in-flight directory/mutation requests live.
    if (previous && previous !== socket) previous.close(1000, "dashboard_replaced");
  }

  private async requestDirectory(cursor: string | null = null, seenCursors = new Set<string>(), pages?: { devices: DashboardDeviceRecord[]; managedDeviceIds: string[] }): Promise<void> {
    const snapshot = pages ?? { devices: [], managedDeviceIds: [] };
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
        return this.requestDirectory(null, new Set<string>());
      }
      throw cause;
    }
    if (frame.schemaId !== "dashboard.directory.v1" || !isDirectory(frame.directory)) throw new Error("Dashboard returned an invalid directory");
    if (frame.directory.revision < (this.revision ?? -1)) return;
    this.revision = frame.directory.revision;
    snapshot.devices.push(...frame.directory.devices);
    snapshot.managedDeviceIds.push(...frame.directory.managedDeviceIds);
    if (frame.directory.nextCursor) {
      await this.requestDirectory(frame.directory.nextCursor, seenCursors, snapshot);
    } else {
      this.options.onDirectory({ ...frame.directory, devices: snapshot.devices, managedDeviceIds: snapshot.managedDeviceIds, nextCursor: null });
    }
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

  private scheduleRefresh(delayMs?: number) {
    if (this.stopped) return;
    const delay = delayMs ?? Math.max(10_000, ((this.ticket?.refreshAfter ?? 0) * 1000) - this.retries.now());
    this.retries.schedule("refresh", delay, () => this.reconnect());
  }

  private scheduleReconnect() {
    if (this.stopped || this.retries.has("reconnect")) return;
    const delay = this.reconnectDelayMs;
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, 60_000);
    this.retries.schedule("reconnect", delay, () => this.reconnect());
  }

  private reconnect(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    // A socket closing during ticket refresh joins the same attempt. Only one
    // owner can install a replacement and decide the next retry deadline.
    if (this.connectionAttempt) return this.connectionAttempt;
    this.retries.cancel("refresh");
    this.retries.cancel("reconnect");
    const attempt = this.replaceConnection().finally(() => {
      this.connectionAttempt = null;
    });
    this.connectionAttempt = attempt;
    return attempt;
  }

  private async replaceConnection() {
    try {
      const replacement = await this.openSession();
      if (this.stopped) return;
      await this.connect(replacement);
      if (this.stopped) return;
      this.ticket = replacement;
      this.retries.cancel("reconnect");
      this.scheduleRefresh();
    } catch (cause) {
      this.fail(cause);
      if (this.socket?.readyState === WebSocket.OPEN) this.scheduleRefresh(60_000);
      else this.scheduleReconnect();
    }
  }

  private fail(cause: unknown) { if (!this.stopped) this.options.onError(cause instanceof Error ? cause.message : "Dashboard request failed"); }
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

export type DashboardRetryClock = {
  readonly now: () => number;
  readonly schedule: (delayMs: number, callback: () => void | Promise<void>) => () => void;
};

const dashboardRetryClock: DashboardRetryClock = {
  now: () => Date.now(),
  schedule: (delayMs, callback) => {
    const timer = setTimeout(() => { void callback(); }, delayMs);
    return () => clearTimeout(timer);
  },
};

// Own every reconnect and ticket-refresh deadline for one team session. Stop
// cancels scheduled work and prevents late async failures from rescheduling it.
class DashboardRetryScheduler {
  private stopped = false;
  private readonly tasks = new Map<string, () => void>();
  constructor(private readonly clock: DashboardRetryClock = dashboardRetryClock) {}
  now() { return this.clock.now(); }
  has(key: string) { return this.tasks.has(key); }
  schedule(key: string, delayMs: number, action: () => Promise<void>) {
    if (this.stopped) return;
    this.tasks.get(key)?.();
    const cancel = this.clock.schedule(delayMs, async () => {
      if (this.stopped || this.tasks.get(key) !== cancel) return;
      this.tasks.delete(key);
      await action();
    });
    this.tasks.set(key, cancel);
  }
  cancel(key: string) {
    this.tasks.get(key)?.();
    this.tasks.delete(key);
  }
  stop() {
    this.stopped = true;
    for (const cancel of this.tasks.values()) cancel();
    this.tasks.clear();
  }
}

function parseFrame(value: unknown): Frame | null { try { const parsed = typeof value === "string" ? JSON.parse(value) : value; return parsed && typeof parsed === "object" ? parsed as Frame : null; } catch { return null; } }
function isTicket(value: unknown): value is Ticket { return !!value && typeof value === "object" && typeof (value as Ticket).token === "string" && typeof (value as Ticket).expiresAt === "number" && typeof (value as Ticket).refreshAfter === "number"; }
function isDirectory(value: unknown): value is DashboardDirectory { if (!value || typeof value !== "object") return false; const candidate = value as DashboardDirectory; return typeof candidate.teamId === "string" && Number.isSafeInteger(candidate.revision) && Array.isArray(candidate.devices) && Array.isArray(candidate.relayURLs) && typeof candidate.canManageTeam === "boolean" && Array.isArray(candidate.managedDeviceIds); }
function errorCode(value: unknown): string | undefined { return value instanceof Error && typeof (value as Error & { code?: unknown }).code === "string" ? (value as Error & { code: string }).code : undefined; }
