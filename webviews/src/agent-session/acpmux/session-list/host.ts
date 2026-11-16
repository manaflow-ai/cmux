import {
  documentSessionListStore,
  SessionListStore,
  LIST_MAX_WANTS,
  type SessionListBatch,
  type SessionListKey,
} from "./store";
import { receiveSessionList, addSessionListHost, removeSessionListHost } from "./receiver";
import { chatRowsNamer } from "../rows/host";

export type SessionListPost = (method: string, params: Record<string, unknown>) => Promise<unknown>;
export type SessionListOpen = { sid: string } | { fallen: string };
export type SessionListResult = { ok: true } | { ok: false; code: string };
export type SessionListPageRequest = {
  kind: "older" | "family" | "forks" | "folder";
  key?: SessionListKey;
  folder?: string;
  cold?: boolean;
};

export const SESSION_LIST_OFF = "list.off";
export const SESSION_LIST_LOST = "list.lost";
export const SESSION_LIST_LATE = "list.late";
export const SESSION_LIST_OPEN_MS = 250;

export const sessionListNamer = chatRowsNamer;

function refusalCode(error: unknown): string {
  const known = error as { code?: unknown; details?: { protocol?: unknown } } | null;
  if (
    known?.details?.protocol === "cmux.protocol.unknown_op" ||
    known?.code === "unsupported" ||
    known?.code === "list.unsupported"
  )
    return SESSION_LIST_OFF;
  if (typeof known?.code === "string" && known.code) return known.code;
  return SESSION_LIST_LOST;
}

function pageFields(request: Record<string, unknown>, kind: SessionListPageRequest["kind"]): Record<string, unknown> {
  const fields: Record<string, unknown> = { kind };
  if (request.key && typeof request.key === "object") fields.key = request.key;
  if (typeof request.folder === "string") fields.folder = request.folder;
  if (typeof request.cold === "boolean") fields.cold = request.cold;
  return fields;
}

function validPageRequest(request: Record<string, unknown>): SessionListPageRequest["kind"] | null {
  const allowed = new Set(["kind", "key", "folder", "cold"]);
  if (Object.keys(request).some((field) => !allowed.has(field))) return null;
  const requested = request.kind;
  if (typeof requested !== "string" || !["older", "family", "forks", "folder"].includes(requested)) return null;
  return requested as SessionListPageRequest["kind"];
}

export class SessionListHost {
  readonly store: SessionListStore;
  private readonly post: SessionListPost;
  private readonly name: () => string;
  private readonly openSids = new Set<string>();
  answerMs = SESSION_LIST_OPEN_MS;

  constructor(post: SessionListPost, store = documentSessionListStore, name = sessionListNamer()) {
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
      this.openSids.add(sid);
      return { sid };
    } catch (error) {
      this.store.close(sid);
      return { fallen: refusalCode(error) };
    } finally {
      clearTimeout(timer);
    }
  }

  close(sid: string): void {
    this.openSids.delete(sid);
    this.store.close(sid);
    void this.post("list.close", { sid }).catch(() => {});
  }

  want(sid: string, keys: readonly SessionListKey[]): Promise<SessionListResult> {
    if (!this.store.has(sid)) return Promise.resolve({ ok: false, code: "list.sid" });
    if (keys.length > LIST_MAX_WANTS) return Promise.resolve({ ok: false, code: "list.limit" });
    return this.post("list.want", { sid, keys }).then(
      () => ({ ok: true }),
      (error) => ({ ok: false, code: refusalCode(error) }),
    );
  }

  unwant(sid: string, keys: readonly SessionListKey[]): Promise<SessionListResult> {
    if (!this.store.has(sid)) return Promise.resolve({ ok: false, code: "list.sid" });
    if (keys.length > LIST_MAX_WANTS) return Promise.resolve({ ok: false, code: "list.limit" });
    return this.post("list.unwant", { sid, keys }).then(
      () => ({ ok: true }),
      (error) => ({ ok: false, code: refusalCode(error) }),
    );
  }

  visible(shown: boolean): Promise<SessionListResult> {
    return this.post("list.visible", { shown }).then(
      () => ({ ok: true }),
      (error) => ({ ok: false, code: refusalCode(error) }),
    );
  }

  /** Starts a page operation; wire continuation and question ids never enter this request. */
  page(
    sid: string,
    request: Record<string, unknown>,
    kind: SessionListPageRequest["kind"],
  ): Promise<string | SessionListResult> {
    const requestedKind = validPageRequest(request);
    if (!requestedKind) return Promise.resolve({ ok: false, code: "list.request" });
    if (!this.store.has(sid)) return Promise.resolve({ ok: false, code: "list.sid" });
    const allowedKind = requestedKind;
    const id = this.name();
    try {
      this.store.questionAsked(sid, id, allowedKind);
    } catch {
      return Promise.resolve({ ok: false, code: "list.busy" });
    }
    const fields = pageFields(request, allowedKind);
    return this.post("list.page", { sid, ...fields }).then(
      (reply) => {
        const remote = typeof (reply as { id?: unknown })?.id === "string" ? (reply as { id: string }).id : id;
        this.store.renameQuestion(sid, id, remote);
        this.store.commit(sid);
        return remote;
      },
      (error) => {
        this.store.apply({ kind: "error", sid, id, code: refusalCode(error) });
        this.store.commit(sid);
        return { ok: false, code: refusalCode(error) };
      },
    );
  }

  next(sid: string, id: string): Promise<SessionListResult> {
    if (!this.store.has(sid)) return Promise.resolve({ ok: false, code: "list.sid" });
    return this.post("list.next", { sid, id }).then(
      () => ({ ok: true }),
      (error) => ({ ok: false, code: refusalCode(error) }),
    );
  }

  closeQuestion(sid: string, id: string): Promise<SessionListResult> {
    if (!this.store.has(sid) || !this.store.closeQuestion(sid, id))
      return Promise.resolve({ ok: false, code: "list.sid" });
    return this.post("list.close", { sid, id }).then(
      () => ({ ok: true }),
      (error) => ({ ok: false, code: refusalCode(error) }),
    );
  }

  receive(event: SessionListBatch): void {
    receiveSessionList(event);
  }

  dispose(): void {
    for (const sid of this.openSids) this.close(sid);
    removeSessionListHost(this);
  }
}
