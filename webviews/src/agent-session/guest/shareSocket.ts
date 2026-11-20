// The guest's side of the room's `cmux.share/1` socket (design/chat-multiplayer.md 4.3): one
// connection to `/v1/chat-shares/<id>/guest`, authenticated by the room's cookie. Each connection
// starts with a `snapshot`; records at or below the newest seq held are dropped, so a record the
// snapshot already had, or one sent twice, folds once. A closed socket reconnects after a one-shot
// backoff timer and gets a fresh snapshot; `end` and `kicked` stop it for good.
import type { EventRecord } from "../acpmux/direct";

export type GuestChat = { title?: string; harness?: string; status?: string };
export type GuestParticipant = { id: string; name: string; kind?: string; viewing?: boolean; typing?: boolean };
export type GuestPromptState = {
  client_id: string;
  prompt_id?: string;
  state: "held" | "approved" | "declined" | "removed" | "refused";
  reason?: string;
};
/** Why the share ended for this guest: the room's `end` reason, or `kicked`. */
export type GuestEnd = "revoked" | "expired" | "closed" | "kicked";
export type GuestConnection = "connecting" | "live" | "reconnecting";

export type ShareSnapshot = {
  chat: GuestChat;
  records: EventRecord[];
  hasMore: boolean;
  prompts: GuestPromptState[];
};

export type ShareListener = {
  snapshot(snapshot: ShareSnapshot): void;
  records(records: EventRecord[]): void;
  page(records: EventRecord[], hasMore: boolean): void;
  presence(participants: GuestParticipant[]): void;
  promptState(state: GuestPromptState): void;
  connection(state: GuestConnection): void;
  ended(reason: GuestEnd): void;
};

/** The part of a WebSocket this client uses, so tests can hand it a fake room. */
export type ShareSocketLike = {
  send(data: string): void;
  close(code?: number): void;
  onopen: (() => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: (() => void) | null;
};

export type ShareSocketOptions = {
  url: string;
  open?: (url: string) => ShareSocketLike;
  setTimer?: (run: () => void, ms: number) => unknown;
  clearTimer?: (timer: unknown) => void;
  /** The client ids of this guest's prompts still waiting on an answer (`prompt_status`). */
  unresolved?: () => string[];
  random?: () => number;
};

/** At most this many client ids ride one `prompt_status` (4.3). */
export const PROMPT_STATUS_MAX = 16;
const BACKOFF_FIRST_MS = 500;
const BACKOFF_MAX_MS = 30_000;
const END_REASONS = new Set(["revoked", "expired", "closed"]);

const isObject = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

/**
 * Room frames are untrusted JSON.  A record's payload is eventually handed to the transcript
 * reducer, where an object in an array is assumed to have its ACP shape.  Keep the decoder as the
 * one trust boundary: optional scalar nulls are fine, but null or an empty object in an array is
 * never a usable ACP value.  An empty object as a field's value is (a tool call's `rawInput: {}`,
 * a call with no arguments), and dropping its record would hide the row.  This also covers new
 * update kinds until their generated protocol type gains a narrower decoder.
 */
function noMalformedContainers(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  if (Array.isArray(value))
    return value.every(
      (entry) => entry !== null && (!isObject(entry) || Object.keys(entry).length > 0) && noMalformedContainers(entry),
    );
  if (!isObject(value)) return true;
  return Object.values(value).every((entry) => noMalformedContainers(entry));
}

function configOptionOf(value: unknown): boolean {
  if (!isObject(value) || typeof value.id !== "string" || !value.id || !Array.isArray(value.options)) return false;
  if (value.name !== undefined && typeof value.name !== "string") return false;
  if (value.category !== undefined && typeof value.category !== "string") return false;
  if (value.currentValue !== undefined && typeof value.currentValue !== "string") return false;
  return value.options.every(
    (choice) =>
      isObject(choice) &&
      typeof choice.value === "string" &&
      (choice.name === undefined || typeof choice.name === "string") &&
      (choice.description === undefined || typeof choice.description === "string") &&
      noMalformedContainers(choice),
  );
}

function sessionUpdateOf(value: unknown): boolean {
  if (!isObject(value) || typeof value.sessionUpdate !== "string" || !value.sessionUpdate) return false;
  if (!noMalformedContainers(value)) return false;
  if (value.sessionUpdate === "config_option_update")
    return Array.isArray(value.configOptions) && value.configOptions.every(configOptionOf);
  if (value.sessionUpdate === "available_commands_update") {
    return (
      Array.isArray(value.availableCommands) &&
      value.availableCommands.every(
        (command) =>
          isObject(command) &&
          typeof command.name === "string" &&
          !!command.name &&
          (command.description === undefined || typeof command.description === "string") &&
          (command.input === undefined || isObject(command.input)) &&
          noMalformedContainers(command),
      )
    );
  }
  return true;
}

/** The reducer reads a permission's options as objects. A malformed ask must not end the chat. */
function readablePermission(msg: Record<string, unknown>): boolean {
  if (msg.request !== undefined && !isObject(msg.request)) return false;
  const request = isObject(msg.request) ? msg.request : msg;
  return (
    (request.options == null || (Array.isArray(request.options) && request.options.every(isObject))) &&
    (request.title == null || typeof request.title === "string")
  );
}

/** Validate the room envelope before handing its payload to the pane's transcript reducer. */
function recordOf(value: unknown): EventRecord | undefined {
  if (
    !isObject(value) ||
    typeof value.seq !== "number" ||
    !Number.isSafeInteger(value.seq) ||
    value.seq <= 0 ||
    (value.dir !== "in" && value.dir !== "out" && value.dir !== "mux" && value.dir !== "peer") ||
    typeof value.kind !== "string" ||
    !value.kind
  )
    return undefined;
  // The daemon relay cuts oversized records to seq/dir/kind and these two fields, with no msg
  // or at. Keep a no-op record so an all-truncated older page still advances historyFrom. Its
  // original kind must not run with an invented payload (e.g. a permission_request or turn_end).
  if (value.truncated === true) {
    if (typeof value.full_bytes !== "number" || !Number.isSafeInteger(value.full_bytes) || value.full_bytes <= 0)
      return undefined;
    return {
      seq: value.seq,
      at: typeof value.at === "number" && Number.isFinite(value.at) ? value.at : 0,
      dir: value.dir,
      kind: "share_truncated",
      msg: {},
    };
  }
  if (typeof value.at !== "number" || !Number.isFinite(value.at) || !isObject(value.msg)) return undefined;
  const msg = value.msg;
  if (msg.method === "session/update") {
    if (!isObject(msg.params) || !sessionUpdateOf(msg.params.update)) return undefined;
  }
  if (value.kind === "permission_request" && !readablePermission(msg)) return undefined;
  return {
    seq: value.seq,
    at: value.at,
    dir: value.dir,
    kind: value.kind,
    msg,
    ...(typeof value.sessionId === "string" ? { sessionId: value.sessionId } : {}),
  };
}

const recordsOf = (value: unknown): EventRecord[] =>
  Array.isArray(value)
    ? value.flatMap((entry) => {
        const record = recordOf(entry);
        return record ? [record] : [];
      })
    : [];

const promptStateOf = (value: unknown): GuestPromptState | undefined => {
  if (
    !isObject(value) ||
    typeof value.client_id !== "string" ||
    !["held", "approved", "declined", "removed", "refused"].includes(String(value.state))
  )
    return undefined;
  return {
    client_id: value.client_id,
    ...(typeof value.prompt_id === "string" ? { prompt_id: value.prompt_id } : {}),
    state: value.state as GuestPromptState["state"],
    ...(typeof value.reason === "string" ? { reason: value.reason } : {}),
  };
};

const participantsOf = (value: unknown): GuestParticipant[] =>
  Array.isArray(value)
    ? value.flatMap((entry) => {
        if (!isObject(entry) || typeof entry.id !== "string" || typeof entry.name !== "string") return [];
        return [
          {
            id: entry.id,
            name: entry.name,
            ...(typeof entry.kind === "string" ? { kind: entry.kind } : {}),
            ...(typeof entry.viewing === "boolean" ? { viewing: entry.viewing } : {}),
            ...(typeof entry.typing === "boolean" ? { typing: entry.typing } : {}),
          },
        ];
      })
    : [];

const chatOf = (value: unknown): GuestChat => {
  if (!isObject(value)) return {};
  return {
    ...(typeof value.title === "string" ? { title: value.title } : {}),
    ...(typeof value.harness === "string" ? { harness: value.harness } : {}),
    ...(typeof value.status === "string" ? { status: value.status } : {}),
  };
};

/** The wait before reconnect number `attempt` (0 first): doubling to 30 s, with up to half of jitter. */
export function backoffMs(attempt: number, random = Math.random): number {
  const base = Math.min(BACKOFF_MAX_MS, BACKOFF_FIRST_MS * 2 ** attempt);
  return Math.round(base / 2 + (base / 2) * random());
}

export class ShareSocket {
  private socket?: ShareSocketLike;
  private timer?: unknown;
  private attempt = 0;
  private stopped = false;
  /** This connection's snapshot came: live records may fold. */
  private synced = false;
  /** The newest seq folded; a record at or below it is a copy. */
  private watermark = 0;
  private readonly open: (url: string) => ShareSocketLike;
  private readonly setTimer: (run: () => void, ms: number) => unknown;
  private readonly clearTimer: (timer: unknown) => void;

  constructor(
    private readonly options: ShareSocketOptions,
    private readonly listener: ShareListener,
  ) {
    this.open = options.open ?? ((url) => new WebSocket(url) as unknown as ShareSocketLike);
    this.setTimer = options.setTimer ?? ((run, ms) => setTimeout(run, ms));
    this.clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  }

  connect(): void {
    if (this.stopped || this.socket) return;
    this.listener.connection(this.attempt === 0 ? "connecting" : "reconnecting");
    this.synced = false;
    const socket = this.open(this.options.url);
    this.socket = socket;
    socket.onmessage = (event) => {
      if (this.socket === socket && typeof event.data === "string") this.receive(event.data);
    };
    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.reconnectLater();
    };
  }

  /** Asks for the page of history before `beforeSeq`; it comes as `page`. */
  older(beforeSeq: number): boolean {
    return this.send({ t: "older", before_seq: beforeSeq });
  }

  /** Sends a guest frame (`prompt`, `typing`) on a synced connection; false when there is none. */
  send(frame: { t: string } & Record<string, unknown>): boolean {
    if (!this.socket || !this.synced) return false;
    this.socket.send(JSON.stringify({ v: 1, ...frame }));
    return true;
  }

  /** Stops for good: closes the socket and cancels a pending reconnect. */
  stop(): void {
    this.stopped = true;
    if (this.timer !== undefined) this.clearTimer(this.timer);
    this.timer = undefined;
    const socket = this.socket;
    this.socket = undefined;
    socket?.close(1000);
  }

  private reconnectLater(): void {
    if (this.stopped || this.timer !== undefined) return;
    this.listener.connection("reconnecting");
    const wait = backoffMs(this.attempt, this.options.random);
    this.attempt += 1;
    this.timer = this.setTimer(() => {
      this.timer = undefined;
      this.connect();
    }, wait);
  }

  private end(reason: GuestEnd): void {
    if (this.stopped) return;
    this.stop();
    this.listener.ended(reason);
  }

  private receive(data: string): void {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(data);
    } catch {
      return;
    }
    if (!frame || frame.v !== 1 || typeof frame.t !== "string") return;
    switch (frame.t) {
      case "snapshot":
        return this.snapshot(frame);
      case "records": {
        if (!this.synced) return;
        const fresh = recordsOf(frame.records).filter((record) => record.seq > this.watermark);
        if (!fresh.length) return;
        this.watermark = Math.max(this.watermark, ...fresh.map((record) => record.seq));
        return this.listener.records(fresh);
      }
      case "page":
        if (this.synced) this.listener.page(recordsOf(frame.records), frame.has_more === true);
        return;
      case "presence":
        this.listener.presence(participantsOf(frame.participants));
        return;
      case "prompt_state":
        {
          const state = promptStateOf(frame);
          if (state) this.listener.promptState(state);
        }
        return;
      case "end":
        return this.end(END_REASONS.has(String(frame.reason)) ? (frame.reason as GuestEnd) : "closed");
      case "kicked":
        return this.end("kicked");
    }
  }

  private snapshot(frame: Record<string, unknown>): void {
    const records = recordsOf(frame.records);
    const watermark = Number(frame.watermark);
    this.watermark = Number.isFinite(watermark)
      ? watermark
      : records.reduce((newest, record) => Math.max(newest, record.seq), 0);
    this.synced = true;
    this.attempt = 0;
    const prompts = Array.isArray(frame.prompts)
      ? frame.prompts.flatMap((prompt) => {
          const parsed = promptStateOf(prompt);
          return parsed ? [parsed] : [];
        })
      : [];
    this.listener.snapshot({
      chat: chatOf(frame.chat),
      records,
      hasMore: frame.has_more === true,
      prompts,
    });
    this.listener.connection("live");
    // Prompts sent before a drop that the snapshot does not answer: ask the host where they are.
    const answered = new Set(prompts.map((prompt) => prompt.client_id));
    const asking = (this.options.unresolved?.() ?? []).filter((id) => !answered.has(id)).slice(0, PROMPT_STATUS_MAX);
    if (asking.length) this.send({ t: "prompt_status", client_ids: asking });
  }
}
