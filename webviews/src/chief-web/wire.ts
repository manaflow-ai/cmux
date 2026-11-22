// Browser side of the iOS Home wire conversation contract. Committed messages use the ordered
// stream; chief-live-v1 text is ephemeral and hands off only when its reply is committed.
import type { AcpmuxRow } from "../agent-session/acpmux/model";

export type ChiefIdentity = {
  handle: string;
  chiefId: string;
  mainConversationId: string;
};
export type ChiefTicket = { ticket: string; websocketUrl: string };
export class ExpiredSession extends Error {}
export class ChiefAccessError extends Error {}
export type ChiefConnection = "connecting" | "live" | "reconnecting" | "expired" | "offline" | "inaccessible";
export type SocketLike = {
  send(data: string): void;
  close(): void;
  onopen: (() => void) | null;
  onmessage: ((event: { data: unknown }) => void | Promise<void>) | null;
  onclose: ((event: { code?: number }) => void) | null;
};
type Timers = { set(run: () => void, ms: number): unknown; clear(timer: unknown): void };
type Options = {
  identity: ChiefIdentity;
  ticket(): Promise<ChiefTicket>;
  open?(url: string, protocols: string[]): SocketLike;
  timers?: Timers;
};
type Callbacks = {
  /** History changes only on ordered-stream writes. Live updates must not copy or walk it. */
  rows(committed: AcpmuxRow[], live: AcpmuxRow[]): void;
  connection(state: ChiefConnection): void;
  accepted?(clientId: string): void;
  /** A run requiring the owner's machine sign-in; status is always confirmed over HTTP. */
  machineLogin?(run: string): void;
};
type Json = Record<string, unknown>;
type Message = {
  id: string;
  seq: number;
  author: string;
  clientId: string;
  row: AcpmuxRow;
  retracted: boolean;
};
type LiveStep = {
  seq: number;
  text: string;
  talk: boolean;
  final: boolean;
  /** Run-row seq is placement, not the live frame sequence. */
  place?: number;
  fromRow?: boolean;
  revision?: number;
};
type LiveRun = {
  id: string;
  author: string;
  turn: string;
  steps: Map<string, LiveStep>;
  row: AcpmuxRow;
  done: boolean;
};

const object = (value: unknown): value is Json => !!value && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const sequence = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const date = (value: unknown) =>
  typeof value === "number" ? value : typeof value === "string" ? Date.parse(value) || 0 : 0;
const clock: Timers = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

/** Keep the transport seam small without depending on DOM event callback variance. */
function browserSocket(url: string, protocols: string[]): SocketLike {
  const native = new WebSocket(url, protocols);
  const socket: SocketLike = {
    send: (data) => native.send(data),
    close: () => native.close(),
    onopen: null,
    onmessage: null,
    onclose: null,
  };
  native.addEventListener("open", () => socket.onopen?.());
  native.addEventListener("message", (event) => socket.onmessage?.({ data: event.data }));
  native.addEventListener("close", (event) => socket.onclose?.({ code: event.code }));
  return socket;
}

export class ChiefWire {
  private readonly timers: Timers;
  private socket?: SocketLike;
  private timer?: unknown;
  private deadline?: unknown;
  private epoch = 0;
  private active = false;
  private disposed = false;
  private attempt = 0;
  private user?: string;
  private lastSeq?: number;
  private subscribed = false;
  private awaitingSnapshot = false;
  private awaitingLive = false;
  private incoming: Promise<void> = Promise.resolve();
  private state?: ChiefConnection;
  private people = new Map<string, { agent: boolean; name?: string; chief: boolean }>();
  private messages = new Map<string, Message>();
  /** Rebuilt only on committed changes, never by a streamed token. */
  private committed: AcpmuxRow[] = [];
  private readonly runs = new Map<string, LiveRun>();
  private readonly ended: string[] = [];
  private loginRun = -1;

  constructor(
    private readonly options: Options,
    private readonly callbacks: Callbacks,
  ) {
    this.timers = options.timers ?? clock;
  }

  connect(): void {
    if (this.active || this.disposed) return;
    this.active = true;
    this.connection("connecting");
    void this.dial();
  }

  retry(): void {
    if (this.disposed) return;
    this.active = true;
    this.attempt = 0;
    this.epoch++;
    this.cancelTimer();
    this.closeSocket();
    this.connection(this.lastSeq === undefined ? "connecting" : "reconnecting");
    void this.dial();
  }

  stop(): void {
    this.disposed = true;
    this.active = false;
    this.epoch++;
    this.cancelTimer();
    this.closeSocket();
  }

  private connection(state: ChiefConnection): void {
    if (this.disposed || this.state === state) return;
    this.state = state;
    this.callbacks.connection(state);
  }

  private async dial(): Promise<void> {
    const epoch = ++this.epoch;
    // A ticket, socket upgrade or first snapshot that never answers gets the same reconnect path.
    // Closing/replacing this attempt cancels its deadline; its late ticket and frames cannot act.
    this.deadline = this.timers.set(() => {
      if (!this.current(epoch)) return;
      this.epoch++;
      this.closeSocket();
      this.reconnect();
    }, 30_000);
    try {
      const { ticket, websocketUrl } = await this.options.ticket();
      if (!this.current(epoch)) return;
      if (!ticket || !websocketUrl) throw new Error("Invalid Chief ticket");
      const socket = (this.options.open ?? browserSocket)(websocketUrl, ["cmux.wire.v1", `ticket.${ticket}`]);
      this.socket = socket;
      this.subscribed = false;
      this.awaitingSnapshot = false;
      this.awaitingLive = false;
      this.incoming = Promise.resolve();
      socket.onmessage = (event) => {
        // Blob decoding is asynchronous; preserve the socket's frame order across its awaits.
        this.incoming = this.incoming
          .then(async () => {
            if (!this.current(epoch, socket)) return;
            const raw =
              typeof event.data === "string" ? event.data : event.data instanceof Blob ? await event.data.text() : "";
            if (!this.current(epoch, socket)) return;
            let frame: unknown;
            try {
              frame = JSON.parse(raw);
            } catch {
              return;
            }
            if (object(frame)) this.frame(frame);
          })
          .catch(() => {
            if (this.current(epoch, socket)) this.snapshot();
          });
        return this.incoming;
      };
      socket.onclose = ({ code }) => {
        if (!this.current(epoch, socket)) return;
        this.closeSocket();
        if (code === 4401) this.expired();
        else if (code === 4403) this.expired("inaccessible");
        else this.reconnect();
      };
    } catch (error) {
      if (!this.current(epoch)) return;
      this.closeSocket();
      if (error instanceof ExpiredSession) this.expired();
      else if (error instanceof ChiefAccessError) this.expired("inaccessible");
      else this.reconnect();
    }
  }

  private current(epoch: number, socket?: SocketLike): boolean {
    return this.active && !this.disposed && this.epoch === epoch && (!socket || this.socket === socket);
  }

  private closeSocket(): void {
    this.cancelDeadline();
    const socket = this.socket;
    this.socket = undefined;
    this.subscribed = false;
    if (!socket) return;
    socket.onmessage = null;
    socket.onclose = null;
    socket.onopen = null;
    socket.close();
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) this.timers.clear(this.timer);
    this.timer = undefined;
  }

  private cancelDeadline(): void {
    if (this.deadline !== undefined) this.timers.clear(this.deadline);
    this.deadline = undefined;
  }

  private reconnect(): void {
    if (!this.active || this.disposed || this.timer !== undefined) return;
    this.connection("reconnecting");
    const delay = Math.min(30_000, 1_000 * 2 ** Math.min(this.attempt++, 5));
    // One bounded backoff; retry, stop and auth expiry cancel it. Each dial mints a fresh ticket.
    this.timer = this.timers.set(() => {
      this.timer = undefined;
      void this.dial();
    }, delay);
  }

  private expired(state: "expired" | "inaccessible" = "expired"): void {
    this.active = false;
    this.cancelTimer();
    this.closeSocket();
    this.connection(state);
  }

  private send(frame: Json): boolean {
    if (!this.socket) return false;
    try {
      this.socket.send(JSON.stringify(frame));
      return true;
    } catch {
      this.closeSocket();
      this.reconnect();
      return false;
    }
  }

  private snapshot(): void {
    if (this.awaitingSnapshot || !this.subscribed) return;
    this.awaitingSnapshot = true;
    this.send({ t: "snapshot.request", pending: [] });
  }

  private liveSnapshot(): void {
    if (this.awaitingLive || !this.subscribed) return;
    this.awaitingLive = true;
    this.send({
      t: "run.live.get",
      type: "run.live.get",
      conversation: this.options.identity.mainConversationId,
    });
  }

  private frame(frame: Json): void {
    const kind = frame.t ?? frame.type;
    if (kind === "welcome") {
      const user = object(frame.principal) ? text(frame.principal.user) : undefined;
      const previousUser = this.user;
      if (!user || user !== this.user) {
        this.lastSeq = undefined;
        this.messages.clear();
        this.committed = [];
        this.runs.clear();
        this.ended.length = 0;
        this.people.clear();
        this.publish();
      }
      this.user = user;
      // The gateway binds each ticket to this Chief. The welcome supplies the principal; /me
      // deliberately exposes no user id. An account change during a reconnect needs a page reload.
      if (!user || (previousUser !== undefined && user !== previousUser)) {
        this.expired();
        return;
      }
      this.attempt = 0;
      this.subscribed = true;
      if (
        !this.send({
          t: "subscribe",
          ...(this.lastSeq === undefined ? {} : { after_seq: this.lastSeq }),
        })
      )
        return;
      this.liveSnapshot();
      // A caught-up resume may replay no events and send no snapshot.
      if (this.lastSeq !== undefined) {
        this.cancelDeadline();
        this.connection("live");
      }
      return;
    }
    if (kind === "error" && frame.code === "auth.forbidden") return this.expired("inaccessible");
    if (!this.subscribed) return;
    if (kind === "snapshot" || kind === "event") {
      if (frame.stream !== `conv:${this.options.identity.mainConversationId}` || !sequence(frame.seq)) return;
      if (kind === "snapshot") this.applySnapshot(frame);
      else if (!this.awaitingSnapshot) {
        if (this.lastSeq !== undefined && frame.seq <= this.lastSeq) return;
        if (this.lastSeq === undefined || frame.seq !== this.lastSeq + 1) return this.snapshot();
        if (!object(frame.effects) || !this.applyEffects(frame.effects)) return this.snapshot();
        this.lastSeq = frame.seq;
      }
      return;
    }
    if (frame.conversation !== this.options.identity.mainConversationId) return;
    if (kind === "conversation-run-changed") this.runChanged(frame);
    else if (kind === "run.live") this.applyLiveSnapshot(frame);
    else if (kind === "step.delta" || kind === "run.activity") this.live(frame, kind);
  }

  private head(value: unknown): value is Json {
    return object(value) && value.id === this.options.identity.mainConversationId;
  }

  private participants(head: Json): void {
    if (!Array.isArray(head.participants)) return;
    this.people = new Map(
      head.participants.flatMap((value) =>
        object(value) && text(value.id)
          ? [
              [
                value.id as string,
                {
                  agent: value.kind === "agent",
                  name: text(value.display_name),
                  chief: value.agent_class === "mux",
                },
              ] as const,
            ]
          : [],
      ),
    );
  }

  private agent(author: string): boolean {
    return this.people.get(author)?.agent ?? author.startsWith("agent_");
  }

  private author(value: unknown): string | undefined {
    return (
      text(value) ??
      [...this.people].find(([, person]) => person.chief)?.[0] ??
      [...this.people].find(([, person]) => person.agent)?.[0]
    );
  }

  private message(value: unknown): Message | undefined {
    if (
      !object(value) ||
      !text(value.id) ||
      value.conversation !== this.options.identity.mainConversationId ||
      !sequence(value.seq) ||
      !text(value.author) ||
      !Array.isArray(value.parts)
    )
      return;
    const author = value.author as string;
    const previous = this.messages.get(value.id as string);
    const parts = value.parts.flatMap((part) => {
      if (!object(part)) return [];
      if (part.type === "text" && typeof part.text === "string") return [part.text];
      return text(part.url) ? [part.url as string] : [];
    });
    return {
      id: value.id as string,
      seq: value.seq,
      author,
      clientId: text(value.client_msg_id) ?? (value.id as string),
      retracted: value.retracted_at !== undefined && value.retracted_at !== null,
      row: {
        id: value.id as string,
        version: (previous?.row.version ?? 0) + 1,
        at: date(value.created_at),
        kind: this.agent(author) ? "assistant" : "user",
        text: parts.join("\n\n"),
        ...(!this.agent(author) && this.people.get(author)?.name
          ? { author: { id: author, name: this.people.get(author)!.name! } }
          : {}),
      },
    };
  }

  private loginNeeded(author: string, run: unknown): void {
    if (author !== this.options.identity.chiefId || typeof run !== "string" || !/^run_[0-9]{1,15}$/.test(run)) return;
    const order = Number(run.slice(4));
    if (order <= this.loginRun) return;
    this.loginRun = order;
    this.callbacks.machineLogin?.(run);
  }

  private put(message: Message): void {
    const previous = this.messages.get(message.id);
    if (!previous && (message.author === this.user || message.author === `user_${this.user}`)) {
      this.callbacks.accepted?.(message.clientId);
    }
    if (!message.retracted) {
      const prefix = `chief-machine-auth:${this.options.identity.chiefId}:`;
      if (message.clientId.startsWith(prefix)) this.loginNeeded(message.author, message.clientId.slice(prefix.length));
    }
    if (message.retracted) this.messages.delete(message.id);
    else this.messages.set(message.id, message);
    for (const [key, run] of this.runs) {
      // The run's `turn` is the persisted message's client nonce. A same-author message can be a
      // later turn, so never settle a live reply merely because the run is done.
      if (run.author === message.author && run.turn === message.clientId) this.end(key);
    }
  }

  private applySnapshot(frame: Json): void {
    this.awaitingSnapshot = false;
    if (!this.head(frame.state) || !object(frame.rows) || frame.rows.table !== "msg" || !Array.isArray(frame.rows.rows))
      return this.snapshot();
    this.participants(frame.state);
    const rows = frame.rows.rows.map((stored) => (object(stored) ? this.message(stored.row) : undefined));
    if (rows.some((row) => !row)) return this.snapshot();
    // A snapshot is a tail window. Keep older history already held across a reconnect.
    const first = rows.reduce((lowest, row) => Math.min(lowest, row!.seq), Infinity);
    const old = this.messages;
    this.messages = new Map([...old].filter(([, message]) => message.seq < first && rows.length > 0));
    for (const row of rows) {
      if (row && old.has(row.id)) this.messages.set(row.id, old.get(row.id)!);
      if (row) this.put(row);
    }
    this.lastSeq = frame.seq as number;
    this.awaitingSnapshot = false;
    this.cancelDeadline();
    this.connection("live");
    this.rebuild();
  }

  private applyEffects(effects: Json): boolean {
    if (!this.head(effects.state) || !Array.isArray(effects.writes)) return false;
    this.participants(effects.state);
    const changes: (Message | string)[] = [];
    for (const write of effects.writes) {
      if (!object(write)) return false;
      if (write.table !== "msg") continue;
      if (write.op === "delete" && text(write.key)) changes.push(write.key as string);
      else if (write.op === "upsert") {
        const message = this.message(write.row);
        if (!message) return false;
        changes.push(message);
      } else return false;
    }
    for (const change of changes) {
      if (typeof change === "string") this.messages.delete(change);
      else this.put(change);
    }
    this.rebuild();
    return true;
  }

  private run(author: string, id: string): LiveRun | undefined {
    const key = `${author}\0${id}`;
    if (this.ended.includes(key)) return;
    let run = this.runs.get(key);
    if (!run) {
      run = {
        id,
        author,
        turn: id,
        steps: new Map(),
        done: false,
        row: {
          id: `chief-live:${key}`,
          version: 0,
          at: Date.now(),
          kind: "assistant",
          text: "",
          streaming: true,
        },
      };
      this.runs.set(key, run);
    }
    return run;
  }

  private end(key: string): void {
    this.runs.delete(key);
    if (!this.ended.includes(key)) this.ended.push(key);
    // Match HomeLiveBook's bounded late-frame tombstones.
    if (this.ended.length > 512) this.ended.shift();
  }

  private live(frame: Json, kind: string): void {
    const author = this.author(frame.author);
    const id = text(frame.run);
    if (!author || !id) return;
    if (kind === "step.delta") {
      if (
        !text(frame.step) ||
        !sequence(frame.seq) ||
        typeof frame.text !== "string" ||
        !["talk", "thought"].includes(String(frame.kind))
      )
        return;
    } else if (typeof frame.line !== "string") return;
    const run = this.run(author, id);
    if (!run || run.done) return;
    if (kind === "step.delta") {
      const step = run.steps.get(frame.step as string);
      const seq = frame.seq as number;
      if (step?.final || (seq > 0 && step && seq <= step.seq)) return;
      if (step?.fromRow && seq > 0) return this.liveSnapshot();
      if (frame.seq !== 0 && (!step || frame.seq !== step.seq + 1)) return this.liveSnapshot();
      run.steps.set(frame.step as string, {
        seq: frame.seq,
        text: (frame.seq === 0 ? "" : (step?.text ?? "")) + frame.text,
        talk: frame.kind === "talk",
        final: frame.final === true,
        place: step?.place,
      });
    }
    this.draw(run);
    this.publish();
  }

  private applyLiveSnapshot(frame: Json): void {
    if (!Array.isArray(frame.runs)) return;
    this.awaitingLive = false;
    const kept = new Set<string>();
    for (const entry of frame.runs) {
      if (!object(entry) || !text(entry.run) || !Array.isArray(entry.steps)) continue;
      const author = this.author(entry.author);
      if (!author) continue;
      const run = this.run(author, entry.run as string);
      if (!run) continue;
      const key = `${author}\0${run.id}`;
      kept.add(key);
      // The owner frees completed talk buffers. Their authoritative rows or final deltas keep
      // their text here until the exact posted reply replaces it, including a mid-run join.
      const listed = new Set(entry.steps.flatMap((step) => (object(step) && text(step.step) ? [step.step] : [])));
      const steps = new Map([...run.steps].filter(([id, step]) => step.talk && (step.final || !listed.has(id))));
      for (const step of entry.steps) {
        if (
          !object(step) ||
          !text(step.step) ||
          !sequence(step.seq) ||
          typeof step.text !== "string" ||
          !["talk", "thought"].includes(String(step.kind))
        )
          continue;
        const old = run.steps.get(step.step as string);
        if (old?.final && old.talk) continue;
        steps.set(
          step.step as string,
          old && !old.fromRow && old.seq >= step.seq && old.text.startsWith(step.text)
            ? old
            : {
                seq: step.seq,
                text: step.text,
                talk: step.kind === "talk",
                final: step.final === true,
                place: old?.place,
              },
        );
      }
      run.steps = steps;
      this.draw(run);
    }
    for (const [key, run] of this.runs) {
      if (kept.has(key) || run.done) continue;
      if ([...run.steps.values()].some((step) => step.talk && step.text)) {
        // An absent run has finished at the owner, but its committed reply may still be in
        // flight. Keep its last text; an unrelated message by this Chief cannot settle it.
        run.done = true;
        this.draw(run);
      } else this.runs.delete(key);
    }
    this.publish();
  }

  private runChanged(frame: Json): void {
    if (
      !object(frame.run) ||
      !text(frame.run.id) ||
      !["running", "done", "failed", "cancelled"].includes(String(frame.run.status))
    )
      return;
    const author = this.author(frame.run.author ?? frame.run.agent);
    if (!author) return;
    if (
      Array.isArray(frame.steps) &&
      frame.steps.some((step) => object(step) && step.id === "machine:sign-in" && step.kind === "note")
    )
      this.loginNeeded(text(frame.run.author ?? frame.run.agent) ?? "", frame.run.id);
    const run = this.run(author, frame.run.id as string);
    if (!run) return;
    run.turn = text(frame.run.turn) ?? run.turn;
    const status = frame.run.status;
    if (
      [...this.messages.values()].some((message) => message.author === author && message.clientId === run.turn) ||
      (status !== "running" && status !== "done")
    )
      this.end(`${author}\0${run.id}`);
    else {
      // These are persisted run rows (`id`, `seq` placement, optional `rev`), not live
      // snapshots (`step`, frame `seq`). A completed step may predate this connection or its
      // final delta may have been missed; use its complete text rather than an empty bubble.
      if (Array.isArray(frame.steps))
        for (const value of frame.steps) {
          if (!object(value) || !text(value.id) || value.kind !== "talk") continue;
          const old = run.steps.get(value.id as string);
          const place = sequence(value.seq) ? value.seq : old?.place;
          if (value.truncated === true || typeof value.text !== "string") {
            if (old && old.place !== place) run.steps.set(value.id as string, { ...old, place });
            continue;
          }
          const revision = sequence(value.rev) ? value.rev : undefined;
          if (old?.revision !== undefined && revision !== undefined && revision < old.revision) continue;
          const complete = status === "done" || value.status === "done";
          const held = !complete && old && !old.fromRow && old.text.startsWith(value.text);
          run.steps.set(
            value.id as string,
            held
              ? { ...old, place, revision }
              : {
                  seq: 0,
                  text: value.text,
                  talk: true,
                  final: complete,
                  fromRow: true,
                  place,
                  revision,
                },
          );
        }
      run.done = run.done || status === "done";
      this.draw(run);
    }
    this.publish();
  }

  private draw(run: LiveRun): void {
    const reply = [...run.steps]
      .filter(([, step]) => step.talk)
      .sort(([a, left], [b, right]) => {
        const segment = (value: string) => Number(/^talk:(\d+)$/.exec(value)?.[1] ?? Number.MAX_SAFE_INTEGER);
        return (left.place ?? segment(a)) - (right.place ?? segment(b));
      })
      .map(([, step]) => step.text)
      .join("\n\n");
    run.row = { ...run.row, version: run.row.version + 1, text: reply, streaming: !run.done };
  }

  private rebuild(): void {
    this.committed = [...this.messages.values()].sort((a, b) => a.seq - b.seq).map((message) => message.row);
    this.publish();
  }

  private publish(): void {
    if (!this.disposed)
      this.callbacks.rows(
        this.committed,
        [...this.runs.values()].map((run) => run.row),
      );
  }
}
