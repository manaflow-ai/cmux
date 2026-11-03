// l10n-allow-file: mock conversations for the dev loop and the gallery, not shipped UI.
// An in-memory `cmux.imessage.*` provider for the browser dev loop (`/imessage/?mock`), the gallery
// and the tests: a few made-up threads (1:1 and group) with paging by `before_rowid` and a live
// `cmux.imessage.changed` stream. Every name and number here is synthetic.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import {
  ImessageOps,
  MESSAGE_PAGE,
  type ImessageAccess,
  type ImessageChanged,
  type ImessageStatus,
  type Message,
  type Thread,
} from "./types";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/**
 * `ready` is a Mac with conversations, `empty` has none, the next four are the mirror's states,
 * and `unknown` is a daemon that does not know the ops yet (every call is an unknown op).
 */
export type MockImessageKind = "ready" | "empty" | "off" | "not_permitted" | "missing" | "error" | "unknown";

interface Seed {
  thread: Omit<Thread, "last_message">;
  /** [minutes before now, from (null for me), text, attachments?] */
  lines: Array<[number, string | null, string | null, Message["attachments"]?]>;
}

const ALEX = "+1 (555) 010-2233";
const SAM = "sam.rivera@example.com";
const JO = "+1 (555) 010-7788";
const PRIYA = "+1 (555) 010-4411";

function seeds(): Seed[] {
  return [
    {
      thread: {
        chat_id: 11,
        guid: "iMessage;+;chat-weekend",
        title: "Weekend hike",
        display_name: "Weekend hike",
        is_group: true,
        service: "iMessage",
        participants: [JO, SAM, PRIYA].sort(),
      },
      lines: [
        [2 * DAY / MINUTE + 300, JO, "Who's in for Saturday?"],
        [2 * DAY / MINUTE + 296, SAM, "Me! Which trail?"],
        [2 * DAY / MINUTE + 295, SAM, "Last time the ridge one was muddy"],
        [2 * DAY / MINUTE + 280, null, "I can drive, I have room for three"],
        [DAY / MINUTE + 30, PRIYA, "Map of the loop", [{ name: "trail-loop.png", mime_type: "image/png" }]],
        [DAY / MINUTE + 28, JO, "Perfect, the loop it is"],
        [42, SAM, "Leaving at 8?"],
        [40, null, "8 works. I'll bring coffee"],
        [39, null, "and the good snacks"],
        [6, PRIYA, "See you all there 🥾"],
      ],
    },
    {
      thread: {
        chat_id: 7,
        guid: "iMessage;-;" + ALEX,
        title: ALEX,
        display_name: null,
        is_group: false,
        service: "iMessage",
        participants: [ALEX],
      },
      lines: [
        [3 * DAY / MINUTE, ALEX, "Did the package arrive?"],
        [3 * DAY / MINUTE - 4, null, "Yes, this morning. Thank you!"],
        [26 * 60, ALEX, "Dinner Thursday still on?"],
        [25 * 60, null, "Yes. 7pm at the usual place"],
        [70, ALEX, "Running 10 min late"],
        [69, ALEX, "Grab us a table?"],
        [68, null, "On it"],
        [18, null, "We're at the back by the window", [{ name: "table.heic", mime_type: "image/heic" }]],
        [3, ALEX, "Be right there"],
      ],
    },
    {
      thread: {
        chat_id: 4,
        guid: "SMS;-;" + PRIYA,
        title: PRIYA,
        display_name: null,
        is_group: false,
        service: "SMS",
        participants: [PRIYA],
      },
      lines: [
        [5 * DAY / MINUTE, PRIYA, "Here's the lease draft", [{ name: "lease-draft.pdf", mime_type: "application/pdf" }]],
        [5 * DAY / MINUTE - 30, null, "Got it, reading tonight"],
      ],
    },
    {
      thread: {
        chat_id: 2,
        guid: "iMessage;-;" + SAM,
        title: SAM,
        display_name: null,
        is_group: false,
        service: "iMessage",
        participants: [SAM],
      },
      lines: [
        [12 * DAY / MINUTE, SAM, "Voice memo from the meeting", [{ name: "Audio Message.caf", mime_type: "audio/x-caf" }]],
        [12 * DAY / MINUTE - 3, null, "Thanks, listening now"],
      ],
    },
  ];
}

/** A long 1:1 thread, so scrolling up pages back. */
function longThread(now: number, startRow: number): { thread: Thread; messages: Message[] } {
  const thread: Omit<Thread, "last_message"> = {
    chat_id: 30,
    guid: "iMessage;-;" + JO,
    title: JO,
    display_name: null,
    is_group: false,
    service: "iMessage",
    participants: [JO],
  };
  const messages: Message[] = [];
  const count = MESSAGE_PAGE * 2 + 20;
  for (let i = 0; i < count; i++) {
    const mine = i % 3 === 0;
    messages.push({
      rowid: startRow + i,
      guid: `long-${i}`,
      chat_id: 30,
      sender: mine ? null : JO,
      is_from_me: mine,
      date_ms: now - (count - i) * 37 * MINUTE,
      text: mine ? `Reply ${i}` : `Message ${i} about the plan`,
      attachments: [],
    });
  }
  return { thread: { ...thread, last_message: preview(messages[messages.length - 1]!) }, messages };
}

function preview(message: Message) {
  return {
    rowid: message.rowid,
    text: message.text ?? null,
    is_from_me: message.is_from_me,
    sender: message.sender ?? null,
    date_ms: message.date_ms ?? null,
    has_attachments: message.attachments.length > 0,
  };
}

export class MockImessageProvider implements PageClient {
  private threads: Thread[] = [];
  private messages = new Map<number, Message[]>();
  private nextRow = 1;
  private revision = 0;
  private readonly listeners = new Set<(event: ImessageChanged) => void>();
  /** Every call, for tests. */
  readonly calls: Array<{ op: string; params: unknown }> = [];

  constructor(
    private kind: MockImessageKind = "ready",
    private readonly now: number = Date.now(),
    options: { long?: boolean } = {},
  ) {
    if (kind === "ready") this.seed(options.long ?? false);
  }

  private seed(long: boolean) {
    for (const { thread, lines } of seeds()) {
      const list: Message[] = lines
        .slice()
        .sort((a, b) => b[0] - a[0])
        .map(([ago, from, text, attachments]) => ({
          rowid: this.nextRow++,
          guid: `m-${this.nextRow}`,
          chat_id: thread.chat_id,
          sender: from,
          is_from_me: from === null,
          date_ms: this.now - ago * MINUTE,
          text,
          attachments: attachments ?? [],
        }));
      this.messages.set(thread.chat_id, list);
      this.threads.push({ ...thread, last_message: preview(list[list.length - 1]!) });
    }
    if (long) {
      const { thread, messages } = longThread(this.now - 20 * DAY, this.nextRow);
      this.nextRow += messages.length;
      this.messages.set(thread.chat_id, messages);
      this.threads.push(thread);
    }
    this.sortThreads();
  }

  private sortThreads() {
    this.threads.sort((a, b) => (b.last_message?.date_ms ?? 0) - (a.last_message?.date_ms ?? 0));
  }

  private access(): ImessageAccess {
    switch (this.kind) {
      case "off":
        return "off";
      case "not_permitted":
        return "not_permitted";
      case "missing":
        return "missing";
      case "error":
        return "error";
      default:
        return "ok";
    }
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.kind === "unknown") throw pageError("cmux.protocol.unknown_op", `unknown op ${op}`);
    const p = (params ?? {}) as { chat_id?: number; before_rowid?: number; limit?: number };
    switch (op) {
      case ImessageOps.status: {
        const status: ImessageStatus = {
          enabled: this.kind !== "off",
          access: this.access(),
          latest_rowid: this.nextRow - 1,
        };
        return status as R;
      }
      case ImessageOps.threads:
        this.refuse();
        return { threads: this.threads.slice(0, p.limit ?? 200) } as R;
      case ImessageOps.messages: {
        this.refuse();
        const all = this.messages.get(Number(p.chat_id)) ?? [];
        const before = p.before_rowid;
        const window = before === undefined ? all : all.filter((m) => m.rowid < before);
        const limit = p.limit ?? MESSAGE_PAGE;
        return { messages: window.slice(Math.max(0, window.length - limit)) } as R;
      }
      case ImessageOps.openFullDiskAccess:
      case "cmux.app.action.run":
        return {} as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  private refuse() {
    if (this.kind === "off") throw pageError("cmux.imessage_disabled", "the Messages mirror is off");
    if (this.kind === "not_permitted") throw pageError("cmux.imessage_not_permitted", "no Full Disk Access");
    if (this.kind === "missing" || this.kind === "error") throw pageError("cmux.imessage_unavailable", "unavailable");
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.kind === "unknown") throw pageError("cmux.protocol.unknown_op", stream);
    if (stream !== ImessageOps.changed) return () => {};
    let seq = 0;
    const listener = (event: ImessageChanged) => onEvent(event as E, ++seq);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  /** A message arrives in `chatId` (tests and the dev loop): stored, then announced. */
  receive(chatId: number, text: string, from: string | null = null, at = this.now): Message {
    const message: Message = {
      rowid: this.nextRow++,
      guid: `live-${this.nextRow}`,
      chat_id: chatId,
      sender: from,
      is_from_me: from === null,
      date_ms: at,
      text,
      attachments: [],
    };
    this.messages.set(chatId, [...(this.messages.get(chatId) ?? []), message]);
    const thread = this.threads.find((t) => t.chat_id === chatId);
    if (thread) thread.last_message = preview(message);
    this.sortThreads();
    this.emit({ chat_ids: [chatId], status_changed: false });
    return message;
  }

  /** The mirror's state changes (the setting, the grant). */
  setKind(kind: MockImessageKind) {
    this.kind = kind;
    if (kind === "ready" && this.threads.length === 0) this.seed(false);
    this.emit({ chat_ids: [], status_changed: true });
  }

  private emit(partial: Pick<ImessageChanged, "chat_ids" | "status_changed">) {
    const event: ImessageChanged = { revision: ++this.revision, latest_rowid: this.nextRow - 1, ...partial };
    for (const listener of this.listeners) listener(event);
  }
}
