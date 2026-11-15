// l10n-allow-file: test fixtures, not shipped UI.
// Review of cmux#41559 (F1, the pane's half): an unpaged `_acpmux/process/list` reply holds only the
// newest processes that fit one reply and counts the rest in `omitted`, so a chat's older processes
// went missing from Session Info. The pane reads the chat's list page by page with `limit` and each
// page's `nextCursor`, as `acpmux process list` does (cli/process.rs).
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e4";
const START = Date.UTC(2026, 10, 12, 1, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const process = (n: number) => ({
  id: `${CHAT}/task-${n}`,
  sessionId: CHAT,
  command: `sleep ${n}`,
  state: n % 2 ? "exited" : "running",
  startedAt: START + n,
});

/// A daemon whose chat ran `count` processes. `paged`: it answers `limit` and `cursor` as acpmux
/// does (hub/processes.rs); unpaged it sends the newest `unpagedFits` and `omitted`. `stuckCursor`:
/// every page names the same cursor. `keepsNoList`: it answers `{}`, with no list at all.
function fakeDaemon(
  count: number,
  mode: { paged: boolean; unpagedFits?: number; stuckCursor?: boolean; keepsNoList?: boolean },
) {
  const all = Array.from({ length: count }, (_, n) => process(n));
  const asked: Record<string, unknown>[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/process/list": {
        asked.push(params);
        if (mode.keepsNoList) return {};
        if (!mode.paged || params?.limit === undefined) {
          const fits = Math.min(all.length, mode.unpagedFits ?? all.length);
          return {
            processes: all.slice(all.length - fits),
            ...(fits < all.length ? { omitted: all.length - fits } : {}),
          };
        }
        const from = params.cursor === undefined ? 0 : all.findIndex((p) => p.id === params.cursor) + 1;
        const rows = all.slice(from, from + params.limit);
        const more = from + rows.length < all.length;
        return { processes: rows, nextCursor: mode.stuckCursor ? all[0]!.id : more ? rows.at(-1)!.id : null };
      }
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, asked, all };
}

async function client(daemon: ReturnType<typeof fakeDaemon>) {
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => {},
    undefined,
    daemon.open,
  );
  await tick();
  return connected;
}

test("a chat's processes past one reply are all read, page by page, oldest first", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, unpagedFits: 300 });
  const reply = await (await client(daemon)).listProcesses(CHAT);
  expect(reply.processes?.map((p: any) => p.id)).toEqual(daemon.all.map((p) => p.id));
  expect(daemon.asked.map((params) => params.cursor ?? null)).toEqual([
    null,
    daemon.all[999]!.id,
    daemon.all[1999]!.id,
  ]);
  expect(daemon.asked.every((params) => params.sessionId === CHAT && params.limit === 1_000)).toBe(true);
});

test("an acpmux that pages nothing is read once, its whole list as before", async () => {
  const daemon = fakeDaemon(40, { paged: false });
  const reply = await (await client(daemon)).listProcesses(CHAT);
  expect(reply.processes).toHaveLength(40);
  expect(daemon.asked).toHaveLength(1);
});

test("a cursor the daemon gives twice ends the read instead of looping", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, stuckCursor: true });
  await expect((await client(daemon)).listProcesses(CHAT)).rejects.toThrow("twice");
  expect(daemon.asked.length).toBeLessThanOrEqual(3);
});

// A daemon that keeps no process list answers `{}`, as the dev mock does (mock.ts): the read stays
// unlisted, so a transcript's running background shell still shows (processes.ts `listed`).
test("a daemon that keeps no list is answered with no list, not an empty one", async () => {
  const daemon = fakeDaemon(0, { paged: true, keepsNoList: true });
  const reply = await (await client(daemon)).listProcesses(CHAT);
  expect(reply.processes).toBeUndefined();
  expect(daemon.asked).toHaveLength(1);
});
