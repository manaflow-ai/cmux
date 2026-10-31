// A client attached to a stand-in acpmux over a fake socket (no browser): `history` is its log.
import { AcpmuxDirectClient } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../../src/agent-session/acpmux/model";

export type FakeRecord = {
  sessionId: string;
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, unknown>;
};
type Step = [dir: string, kind: string, msg: Record<string, unknown>];

/// `steps` as acpmux records them, one second apart from `start`.
export function records(sessionId: string, steps: Step[], start = Date.UTC(2026, 9, 25, 9, 0, 0)): FakeRecord[] {
  return steps.map(([dir, kind, msg], index) => ({
    sessionId,
    seq: index + 1,
    at: start + index * 1000,
    dir,
    kind,
    msg,
  }));
}

/// acpmux's paging: `kinds` (a category or exact kinds), the newest `limit` before `beforeSeq`, or
/// the first `limit` after `afterSeq`.
export function pageOf(history: FakeRecord[], params: Record<string, any>) {
  const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds : undefined;
  const lastSeq = history.at(-1)?.seq ?? 0;
  const matching = history.filter(
    (event) => !kinds || kinds.some((kind) => kind === "transcript" || kind === "all" || kind === event.kind),
  );
  const limit = Number(params.limit ?? 5000);
  if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
    const after = matching.filter((event) => event.seq > params.afterSeq);
    return { events: after.slice(0, limit), hasMore: after.length > limit, lastSeq };
  }
  const before = matching.filter((event) => event.seq < (params.beforeSeq ?? Infinity));
  return { events: before.slice(Math.max(0, before.length - limit)), hasMore: before.length > limit, lastSeq };
}

/// A client on `history` whose attach page holds its newest `page` records. `sessions` is the list
/// acpmux gives; `more()` adds to it later, as a watch page or a new chat does.
export async function fakeClient(
  history: FakeRecord[],
  { page = history.length, sessions = [] as Record<string, unknown>[] } = {},
) {
  const sessionId = history[0]!.sessionId;
  const session = {
    sessionId,
    cwd: "/home/dev/x",
    title: "x",
    name: "this-chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: history[0]!.at,
  };
  const reads: Record<string, any>[] = [];
  let socket: any;
  const answer = (method: string, params: Record<string, any>) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session, ...sessions] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)!.seq, events: history.slice(-page), hasMore: page < history.length };
      case "_acpmux/events":
        reads.push(params);
        return pageOf(history, params);
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params ?? {}),
              }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  let snapshot: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId },
    (next: any) => {
      if (next?.type === "snapshot") snapshot = next;
    },
    undefined,
    open,
  );
  await settle();
  /// A notification from acpmux, as it streams them.
  const notify = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  return {
    client,
    reads,
    snapshot: () => snapshot!,
    rows: (): AcpmuxRow[] => snapshot?.rows ?? [],
    notify,
    /// Records acpmux appends and streams now.
    push(steps: Step[]) {
      for (const [dir, kind, msg] of steps) {
        const event = { sessionId, seq: history.at(-1)!.seq + 1, at: history.at(-1)!.at + 1000, dir, kind, msg };
        history.push(event);
        notify("_acpmux/event", event);
      }
    },
    /// The chat list gains `added` (a watch page, a new chat).
    list(added: Record<string, unknown>[]) {
      sessions.push(...added);
      for (const session of added)
        notify("_acpmux/session_changed", { sessionId: session.sessionId, session, kind: "created" });
    },
  };
}

/// Lets queued microtasks and timers (idle callbacks fall back to them) run.
export async function settle(rounds = 20): Promise<void> {
  for (let n = 0; n < rounds; n++) await new Promise((resolve) => setTimeout(resolve, 0));
}
