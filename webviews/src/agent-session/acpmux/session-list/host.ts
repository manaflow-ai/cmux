import { SessionListStore, LIST_MAX_QUESTIONS, LIST_MAX_WANTS } from "./store";
import { receiveSessionList, addSessionListHost, removeSessionListHost } from "./receiver";

export type SessionListPost = (method: string, params: Record<string, unknown>) => Promise<unknown>;
export type SessionListBatch = { batch: number; changes: readonly unknown[] };
export type SessionListOpen = { sid: string } | { fallen: string };

export const SESSION_LIST_OFF = "list.off";
export const SESSION_LIST_LOST = "list.lost";
export const SESSION_LIST_LATE = "list.late";
export const SESSION_LIST_OPEN_MS = 250;

export function sessionListNamer(): () => string {
  const bits = new Uint32Array(2);
  crypto.getRandomValues(bits);
  const prefix = Array.from(bits, (word) => word.toString(16).padStart(8, "0")).join("");
  let next = 0;
  return () => `${prefix}.${++next}`;
}

function refusalCode(error: unknown): string {
  const known = error as { code?: unknown; details?: { protocol?: unknown } } | null;
  if (known?.details?.protocol === "cmux.protocol.unknown_op" || known?.code === "unsupported") return SESSION_LIST_OFF;
  if (typeof known?.code === "string" && known.code) return known.code;
  return SESSION_LIST_LOST;
}

export class SessionListHost {
  readonly store: SessionListStore;
  private readonly post: SessionListPost;
  private readonly name: () => string;
  answerMs = SESSION_LIST_OPEN_MS;

  constructor(post: SessionListPost, store = new SessionListStore(), name = sessionListNamer()) {
    this.post = post;
    this.store = store;
    this.name = name;
    addSessionListHost(this, post);
  }

  async open(view: "live" | "all" | "folders" = "all"): Promise<SessionListOpen> {
    const sid = this.name();
    this.store.open(sid);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<typeof SESSION_LIST_LATE>((resolve) => {
      timer = setTimeout(() => resolve(SESSION_LIST_LATE), this.answerMs);
    });
    try {
      const reply = await Promise.race([this.post("list.open", { sid, view }), late]);
      if (reply === SESSION_LIST_LATE) {
        this.close(sid);
        return { fallen: SESSION_LIST_LATE };
      }
      if ((reply as { sid?: unknown } | null)?.sid !== sid) {
        this.close(sid);
        return { fallen: SESSION_LIST_OFF };
      }
      return { sid };
    } catch (error) {
      this.store.close(sid);
      return { fallen: refusalCode(error) };
    } finally {
      clearTimeout(timer);
    }
  }

  close(sid: string): void {
    this.store.close(sid);
    void this.post("list.close", { sid }).catch(() => {});
  }

  want(sid: string, keys: readonly { origin: string; chatId: string }[]): Promise<boolean> {
    if (keys.length > LIST_MAX_WANTS) return Promise.resolve(false);
    return this.post("list.want", { sid, keys }).then(
      () => true,
      () => false,
    );
  }

  unwant(sid: string, keys: readonly { origin: string; chatId: string }[]): void {
    if (keys.length > LIST_MAX_WANTS) return;
    void this.post("list.unwant", { sid, keys }).catch(() => {});
  }

  page(sid: string, request: Record<string, unknown>, kind = "all"): Promise<string | null> {
    const id = this.name();
    try {
      this.store.questionAsked(sid, id, kind);
    } catch {
      return Promise.resolve(null);
    }
    return this.post("list.page", { sid, id, kind, ...request }).then(
      (reply) => {
        const remote = typeof (reply as { id?: unknown })?.id === "string" ? (reply as { id: string }).id : id;
        this.store.renameQuestion(sid, id, remote);
        this.store.commit(sid);
        return remote;
      },
      () => null,
    );
  }

  next(sid: string, id: string): Promise<boolean> {
    return this.post("list.next", { sid, id }).then(
      () => true,
      () => false,
    );
  }

  receive(event: SessionListBatch): void {
    receiveSessionList(event);
  }

  dispose(): void {
    removeSessionListHost(this);
  }
}
