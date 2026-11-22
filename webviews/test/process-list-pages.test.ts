// l10n-allow-file: test fixtures, not shipped UI.
// Review of cmux#41559 (F1, the pane's half): an unpaged `_acpmux/process/list` reply holds only the
// newest processes that fit one reply and counts the rest in `omitted`, so a chat's older processes
// went missing from Session Info. The pane reads the chat's list page by page with `limit` and each
// page's `nextCursor`, as `acpmux process list` does (cli/process.rs).
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e4";
const START = Date.UTC(2026, 10, 12, 1, 0, 0);
const FAIL = Symbol("fail");
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
/// `endlessCursors`: every page is empty and names a new cursor. `ignoresLimit`: an older acpmux that
/// takes `limit` but answers the unpaged reply. `changesBetweenPages`: the row a page ends on changes
/// before the next read, which lists it again, as a list ordered by update would. `failsPage`: that
/// page (1 is the first) answers an error.
function fakeDaemon(
  count: number,
  mode: {
    paged: boolean;
    unpagedFits?: number;
    stuckCursor?: boolean;
    keepsNoList?: boolean;
    endlessCursors?: boolean;
    ignoresLimit?: boolean;
    changesBetweenPages?: boolean;
    failsPage?: number;
    refusesRecent?: boolean;
    ignoresRecent?: boolean;
  },
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
        if (mode.failsPage === asked.length) return FAIL;
        if (mode.keepsNoList) return {};
        if (params?.recent !== undefined && !mode.ignoresRecent) {
          // acpmux `recent` (hub/processes.rs recent_snapshot): every running one, the newest ended.
          if (mode.refusesRecent) return FAIL;
          let ended = all.filter((p) => p.state !== "running").length;
          const kept = all.filter((p) => p.state === "running" || ended-- <= params.recent);
          return {
            processes: kept,
            recent: params.recent,
            ...(kept.length < all.length ? { omitted: all.length - kept.length } : {}),
          };
        }
        if (mode.endlessCursors) return { processes: [], nextCursor: `cursor-${asked.length}` };
        if (!mode.paged || mode.ignoresLimit || params?.limit === undefined) {
          const fits = Math.min(all.length, mode.unpagedFits ?? all.length);
          return {
            processes: all.slice(all.length - fits),
            ...(fits < all.length ? { omitted: all.length - fits } : {}),
          };
        }
        const after = params.cursor === undefined ? -1 : all.findIndex((p) => p.id === params.cursor);
        // The row the last page ended on changed since: this page lists it again, with its new state.
        const relist = mode.changesBetweenPages === true && after >= 0;
        if (relist) all[after] = { ...all[after]!, state: "changed" };
        const from = relist ? after : after + 1;
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
          queueMicrotask(() => {
            const result = answer(message.method, message.params);
            socket.onmessage?.({
              data: JSON.stringify(
                result === FAIL
                  ? { jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "page lost" } }
                  : { jsonrpc: "2.0", id: message.id, result },
              ),
            });
          });
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

test("a daemon that names new cursors without end is read at most 100 pages", async () => {
  const daemon = fakeDaemon(0, { paged: true, endlessCursors: true });
  await expect((await client(daemon)).listProcesses(CHAT)).rejects.toThrow("pages");
  expect(daemon.asked).toHaveLength(100);
});

test("a process listed on two pages is kept once, at its first place, with the newer row", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, changesBetweenPages: true });
  const reply = await (await client(daemon)).listProcesses(CHAT);
  const ids = reply.processes?.map((p: any) => p.id) ?? [];
  expect(ids).toEqual(daemon.all.map((p) => p.id));
  expect((reply.processes?.[999] as any)?.state).toBe("changed");
});

test("an older acpmux that ignores limit has its omitted count passed on", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, ignoresLimit: true, unpagedFits: 300 });
  const reply = await (await client(daemon)).listProcesses(CHAT);
  expect(reply.processes).toHaveLength(300);
  expect(reply.omitted).toBe(2_200);
  expect(daemon.asked).toHaveLength(1);
});

test("a page that fails fails the whole read, with no partial list", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, failsPage: 2 });
  await expect((await client(daemon)).listProcesses(CHAT)).rejects.toThrow();
  expect(daemon.asked).toHaveLength(2);
});

// A god chat ran 56,000 shells; its page read all 66 MB of them for a tray of a few (2026-11-16).
test("a recent read is one request: every running process and only the newest ended", async () => {
  const daemon = fakeDaemon(2_500, { paged: true });
  const reply = await (await client(daemon)).listProcesses(CHAT, 100);
  const kept = reply.processes as { id: string; state: string }[];
  expect(daemon.asked).toEqual([{ sessionId: CHAT, recent: 100 }]);
  expect(kept.filter((p) => p.state === "running")).toHaveLength(1_250);
  expect(kept.filter((p) => p.state !== "running").map((p) => p.id)).toEqual(
    daemon.all
      .filter((p) => p.state !== "running")
      .slice(-100)
      .map((p) => p.id),
  );
  expect(reply.omitted).toBe(1_150);
});

test("a daemon or host that refuses recent is read whole, page by page, as before", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, refusesRecent: true });
  const reply = await (await client(daemon)).listProcesses(CHAT, 100);
  expect(reply.processes).toHaveLength(2_500);
  expect((reply.processes as { id: string; state: string }[]).filter((p) => p.state === "running")).toEqual(
    daemon.all.filter((p) => p.state === "running"),
  );
  expect(daemon.asked.map((params) => params.recent ?? params.limit)).toEqual([100, 1_000, 1_000, 1_000]);
});

test("a failed page after recent overflow rejects the incomplete running set", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, refusesRecent: true, failsPage: 3 });
  await expect((await client(daemon)).listProcesses(CHAT, 100)).rejects.toThrow();
});

// An older acpmux ignores `recent` and answers its unpaged list (the newest that fit one reply), which
// can leave out an old running process: with no `recent` echoed, the list is read whole.
test("an acpmux that ignores recent is read whole, page by page", async () => {
  const daemon = fakeDaemon(2_500, { paged: true, ignoresRecent: true, unpagedFits: 300 });
  const reply = await (await client(daemon)).listProcesses(CHAT, 100);
  expect(reply.processes).toHaveLength(2_500);
  expect(daemon.asked.map((params) => params.recent ?? params.limit)).toEqual([100, 1_000, 1_000, 1_000]);
});
