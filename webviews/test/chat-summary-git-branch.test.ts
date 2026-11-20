// l10n-allow-file: test fixtures, not shipped UI.
// Review of #23259: acpmux's session detail names the folder's branch `gitBranch`
// (cmux-tui/crates/acpmux/src/hub/views.rs session_detail), never `branch`, so the chat header's
// Environment line and Session Info's Environment showed no branch for any real chat. acpmux keeps
// it live (hub/git_watch.rs): a checkout mid-session reaches a client holding the chat as
// `_acpmux/session_changed` kind `git`, and the header and Session Info follow it.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e1";

/// A daemon whose attach answers `session` as acpmux's session detail.
function fakeDaemon(session: Record<string, unknown>) {
  let socket: any;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: 0 };
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
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const notify = (method: string, params: Record<string, unknown>) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  return { open, notify };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function connect(fields: Record<string, unknown>) {
  let summary: any;
  const session = { sessionId: CHAT, cwd: "/home/dev/app", title: "x", harness: "claude", status: "ready", ...fields };
  const daemon = fakeDaemon(session);
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (summary = snapshot.summary),
    undefined,
    daemon.open,
  );
  await settle();
  /// acpmux read the folder's HEAD again: the summary's `gitBranch` is the branch now.
  const checkout = async (gitBranch: string | null) => {
    daemon.notify("_acpmux/session_changed", {
      sessionId: CHAT,
      kind: "git",
      recordKind: "git",
      session: { ...session, gitBranch },
    });
    await settle();
  };
  return { shownBranch: () => summary?.branch, checkout };
}

test("a chat's summary names the branch acpmux reports as gitBranch", async () => {
  const { shownBranch } = await connect({ gitBranch: "feat/inspector", gitHead: "0123abcd" });
  expect(shownBranch()).toBe("feat/inspector");
});

test("a folder outside git, or on a detached HEAD, has no branch", async () => {
  const { shownBranch } = await connect({ gitBranch: null, gitHead: null });
  expect(shownBranch()).toBeUndefined();
});

test("a checkout mid-session moves the branch the chat shows; a detached HEAD clears it", async () => {
  const { shownBranch, checkout } = await connect({ gitBranch: "first", gitHead: "0123abcd" });
  expect(shownBranch()).toBe("first");
  await checkout("second");
  expect(shownBranch()).toBe("second");
  await checkout(null);
  expect(shownBranch()).toBeUndefined();
});
