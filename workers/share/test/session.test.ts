// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  deliveryCreditBytes,
  MAX_SOCKET_OUTSTANDING_BYTES,
} from "../src/outbound";
import {
  BINARY_KIND_GRID,
  encodeBinaryHeader,
  MAX_BINARY_FRAME_BYTES,
  MAX_EMAIL_BYTES,
  MAX_ID_BYTES,
  MAX_LAYOUT_PANES,
  MAX_SERVER_JSON_FRAME_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  MAX_TITLE_BYTES,
  PROTO_VERSION,
} from "../src/protocol";
import type { LayoutNode, ServerMessage } from "../src/protocol";
import {
  CHAT_HISTORY_BYTE_LIMIT,
  CHAT_HISTORY_LIMIT,
  CHAT_RATE_LIMIT_PER_ROOM,
  CHAT_RATE_LIMIT_PER_SOCKET,
  CHAT_TEXT_LIMIT,
  CURSOR_ROOM_DELIVERY_LIMIT,
  CURSOR_ROOM_SOURCE_LIMIT,
  CURSOR_RATE_LIMIT,
  CURSOR_RATE_WINDOW_MS,
  ENDED_TOMBSTONE_RETENTION_MS,
  HOST_GRACE_MS,
  MAX_CONNECTIONS_PER_SESSION,
  MAX_DENIED_PER_SESSION,
  MAX_GRANTS_PER_SESSION,
  MAX_PENDING_REQUESTS_PER_SESSION,
  INPUT_RATE_LIMIT_PER_ROOM,
  INPUT_RATE_LIMIT_PER_SOCKET,
  RATE_LIMIT_CLOSE_CODE,
  SUB_RATE_LIMIT_PER_ROOM,
  SUB_RATE_LIMIT_PER_SOCKET,
  restorePersistedSession,
  ShareSessionCore,
} from "../src/session";
import type { Effect } from "../src/session";
import type { PersistedSession } from "../src/session";

const T0 = 1_700_000_000_000;
const HOST = { user: "u-host", email: "host@cmux.com", hostToken: true };
const ALICE = { user: "u-alice", email: "alice@example.com", hostToken: false };
const BOB = { user: "u-bob", email: "bob@example.com", hostToken: false };

function newCore(): ShareSessionCore {
  return new ShareSessionCore(
    ShareSessionCore.create("code123", { user: HOST.user, email: HOST.email }, T0),
  );
}

/** Boot a session with a connected host that shared one workspace. */
function bootedCore(): ShareSessionCore {
  const core = newCore();
  core.connect("c-host", HOST, T0);
  core.handleHost("c-host", {
    t: "hello",
    proto: PROTO_VERSION,
    shared: [{ id: "workspace:1", title: "main" }],
    layouts: [
      {
        ws: "workspace:1",
        tree: { kind: "pane", pane: "surface:1", content: "terminal", cols: 80, rows: 24 },
      },
    ],
  });
  return core;
}

function approveGuest(
  core: ShareSessionCore,
  connId: string,
  who: { user: string; email: string; hostToken: boolean },
  role: "editor" | "viewer" = "editor",
): void {
  core.connect(connId, who, T0);
  core.handleHost("c-host", { t: "approve", user: who.user, role });
}

function terminalTree(count: number, start = 0): LayoutNode {
  if (count === 1) {
    return {
      kind: "pane",
      pane: `surface:${start}`,
      content: "terminal",
      cols: 80,
      rows: 24,
    };
  }
  const left = Math.floor(count / 2);
  return {
    kind: "split",
    axis: "h",
    ratio: 0.5,
    a: terminalTree(left, start),
    b: terminalTree(count - left, start + left),
  };
}

function maxString(prefix: string, index: number, bytes: number): string {
  const suffix = index.toString().padStart(6, "0");
  return `${prefix}${"x".repeat(bytes - prefix.length - suffix.length)}${suffix}`;
}

function maxTerminalTree(count: number, start = 0): LayoutNode {
  if (count === 1) {
    return {
      kind: "pane",
      pane: maxString("p", start, MAX_ID_BYTES),
      content: "terminal",
      cols: 10_000,
      rows: 10_000,
      title: "t".repeat(MAX_TITLE_BYTES),
    };
  }
  const left = Math.floor(count / 2);
  return {
    kind: "split",
    axis: start % 2 === 0 ? "h" : "v",
    ratio: 0.5,
    a: maxTerminalTree(left, start),
    b: maxTerminalTree(count - left, start + left),
  };
}

function worstCasePersistedSession(): PersistedSession {
  const host = {
    user: maxString("h", 0, MAX_ID_BYTES),
    email: maxString("e", 0, MAX_EMAIL_BYTES),
  };
  const ws = maxString("w", 0, MAX_ID_BYTES);
  const firstPane = maxString("p", 0, MAX_ID_BYTES);
  const raw = {
    ...ShareSessionCore.create(maxString("c", 0, MAX_ID_BYTES), host, T0),
    shared: [{ id: ws, title: "t".repeat(MAX_TITLE_BYTES) }],
    layouts: [{ ws, tree: maxTerminalTree(MAX_LAYOUT_PANES) }],
    grants: Array.from({ length: MAX_GRANTS_PER_SESSION }, (_, index) => ({
      user: maxString("u", index, MAX_ID_BYTES),
      email: maxString("e", index + 1, MAX_EMAIL_BYTES),
      role: index % 2 === 0 ? ("editor" as const) : ("viewer" as const),
      color: index % 8,
    })),
    denied: Array.from({ length: MAX_DENIED_PER_SESSION }, (_, index) =>
      maxString("d", index, MAX_ID_BYTES),
    ),
    chat: Array.from({ length: CHAT_HISTORY_LIMIT }, (_, index) => ({
      id: maxString("m", index, MAX_ID_BYTES),
      user: host.user,
      text: `${index.toString().padStart(6, "0")}${"z".repeat(CHAT_TEXT_LIMIT - 6)}`,
      bubble: { ws, pane: firstPane, x: 0.5, y: 0.5 },
      ts: T0 + index,
    })),
  };
  const restored = restorePersistedSession(raw);
  if (!restored) throw new Error("worst-case state did not validate");
  return restored;
}

function sends(effects: Effect[], to?: string): ServerMessage[] {
  return effects
    .filter((e): e is Extract<Effect, { kind: "send" }> => e.kind === "send")
    .filter((e) => to === undefined || e.to === to)
    .map((e) => e.msg);
}

function closes(effects: Effect[]): Array<{ to: string; code: number }> {
  return effects
    .filter((e): e is Extract<Effect, { kind: "close" }> => e.kind === "close")
    .map((e) => ({ to: e.to, code: e.code }));
}

function expectCapacityRejection(
  effects: Effect[],
  to: string,
  code: "session_full" | "too_many_pending",
): void {
  expect(effects).toHaveLength(2);

  const error = effects[0];
  if (error?.kind !== "send" || error.msg.t !== "error") {
    throw new Error("expected an error before the capacity close");
  }
  expect(error.to).toBe(to);
  expect(error.msg.code).toBe(code);
  expect(error.msg.message.trim().length).toBeGreaterThan(0);

  const close = effects[1];
  if (close?.kind !== "close") {
    throw new Error("expected a capacity close after the error");
  }
  expect(close.to).toBe(to);
  expect(close.code).toBe(4429);
  expect(close.reason.trim().length).toBeGreaterThan(0);
}

describe("join and approval flow", () => {
  it("host connect gets a snapshot and clears the grace alarm", () => {
    const core = newCore();
    const effects = core.connect("c-host", HOST, T0);
    expect(effects.some((e) => e.kind === "clearAlarm")).toBe(true);
    const snapshot = sends(effects, "c-host").find((m) => m.t === "session-state");
    expect(snapshot).toBeDefined();
    if (snapshot?.t === "session-state") {
      expect(snapshot.you.isHost).toBe(true);
      expect(snapshot.you.color).toBe(0);
    }
  });

  it("guest waits pending and the host sees an access request", () => {
    const core = bootedCore();
    const effects = core.connect("c-alice", ALICE, T0);
    expect(sends(effects, "c-alice")).toEqual([{ t: "access-pending" }]);
    expect(sends(effects, "c-host")).toEqual([
      { t: "access-request", user: ALICE.user, email: ALICE.email },
    ]);
  });

  it("approve activates the pending connection with a snapshot and color", () => {
    const core = bootedCore();
    core.connect("c-alice", ALICE, T0);
    const effects = core.handleHost("c-host", { t: "approve", user: ALICE.user, role: "editor" });
    const snapshot = sends(effects, "c-alice").find((m) => m.t === "session-state");
    expect(snapshot).toBeDefined();
    if (snapshot?.t === "session-state") {
      expect(snapshot.you.role).toBe("editor");
      expect(snapshot.you.color).toBe(1);
      expect(snapshot.shared).toHaveLength(1);
      expect(snapshot.layouts).toHaveLength(1);
    }
  });

  it("approval is remembered for the session: a rejoin skips the ask", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.disconnect("c-alice", T0 + 1000);
    const effects = core.connect("c-alice2", ALICE, T0 + 2000);
    expect(sends(effects, "c-alice2").some((m) => m.t === "session-state")).toBe(true);
    expect(sends(effects, "c-host").some((m) => m.t === "access-request")).toBe(false);
  });

  it("deny closes the guest and blocks re-requests for the session", () => {
    const core = bootedCore();
    core.connect("c-alice", ALICE, T0);
    const denyEffects = core.handleHost("c-host", { t: "deny", user: ALICE.user });
    expect(sends(denyEffects, "c-alice")).toContainEqual({ t: "access-denied" });
    expect(closes(denyEffects)).toContainEqual({ to: "c-alice", code: 4003 });
    // Re-request is refused without bothering the host.
    const retry = core.connect("c-alice2", ALICE, T0 + 1000);
    expect(sends(retry, "c-alice2")).toContainEqual({ t: "access-denied" });
    expect(sends(retry, "c-host")).toEqual([]);
  });

  it("a reconnecting host supersedes the previous host socket", () => {
    const core = bootedCore();
    const effects = core.connect("c-host2", HOST, T0 + 1000);
    expect(closes(effects)).toContainEqual({ to: "c-host", code: 4000 });
    expect(sends(effects, "c-host2").some((m) => m.t === "session-state")).toBe(true);
  });

  it("the host user with a guest token joins as a guest without superseding the Mac socket", () => {
    const core = bootedCore();
    const effects = core.connect(
      "c-host-web",
      { user: HOST.user, email: HOST.email, hostToken: false },
      T0,
    );
    // No approval needed, no host socket closed.
    expect(closes(effects)).toEqual([]);
    const snapshot = sends(effects, "c-host-web").find((m) => m.t === "session-state");
    if (snapshot?.t === "session-state") {
      expect(snapshot.you.isHost).toBe(false);
      expect(snapshot.you.role).toBe("editor");
      expect(snapshot.you.color).toBe(0);
    } else {
      throw new Error("expected snapshot");
    }
    // Its input relays to the real host socket like any editor guest.
    const relayed = core.handleGuest("c-host-web", {
      t: "input",
      ws: "workspace:1",
      pane: "surface:1",
      data: "w",
    });
    expect(sends(relayed, "c-host").some((m) => m.t === "guest-input")).toBe(true);
    // And it cannot exercise host moderation verbs.
    core.connect("c-alice", ALICE, T0);
    expect(core.handleHost("c-host-web", { t: "approve", user: ALICE.user, role: "editor" })).toEqual([]);
  });

  it("pending requests are re-surfaced to a reconnecting host", () => {
    const core = bootedCore();
    core.connect("c-alice", ALICE, T0);
    core.disconnect("c-host", T0 + 1000);
    const effects = core.connect("c-host2", HOST, T0 + 2000);
    expect(sends(effects, "c-host2")).toContainEqual({
      t: "access-request",
      user: ALICE.user,
      email: ALICE.email,
    });
  });

  it("caps total connections at N and does not retain the N+1 socket", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice-0", ALICE);

    // One host plus 31 approved sockets for the same user reaches the cap
    // without consuming pending-request capacity.
    for (let i = 1; i < MAX_CONNECTIONS_PER_SESSION - 1; i += 1) {
      const effects = core.connect(`c-alice-${i}`, ALICE, T0 + i);
      expect(sends(effects, `c-alice-${i}`).some((m) => m.t === "session-state")).toBe(true);
    }

    const overflow = {
      user: "u-overflow",
      email: "overflow@example.com",
      hostToken: false,
    };
    const rejected = core.connect("c-overflow", overflow, T0 + 100);
    expectCapacityRejection(rejected, "c-overflow", "session_full");

    // A host reconnect at capacity must replace the old host. The rejected
    // socket was never retained, so its user cannot surface as pending.
    const reconnected = core.connect("c-host-2", HOST, T0 + 101);
    expect(closes(reconnected)).toContainEqual({ to: "c-host", code: 4000 });
    expect(sends(reconnected, "c-host-2")).not.toContainEqual({
      t: "access-request",
      user: overflow.user,
      email: overflow.email,
    });

    // Releasing one accepted socket makes exactly one slot available.
    core.disconnect("c-alice-1", T0 + 102);
    const retry = core.connect("c-overflow-retry", overflow, T0 + 103);
    expect(sends(retry, "c-overflow-retry")).toEqual([{ t: "access-pending" }]);
    expect(sends(retry, "c-host-2")).toEqual([
      { t: "access-request", user: overflow.user, email: overflow.email },
    ]);
  });

  it("caps pending requests at N and does not retain the N+1 request", () => {
    const core = bootedCore();
    const pending = Array.from({ length: MAX_PENDING_REQUESTS_PER_SESSION }, (_, i) => ({
      conn: `c-pending-${i}`,
      user: `u-pending-${i}`,
      email: `pending-${i}@example.com`,
      hostToken: false,
    }));

    for (const { conn, ...who } of pending) {
      const effects = core.connect(conn, who, T0);
      expect(sends(effects, conn)).toEqual([{ t: "access-pending" }]);
      expect(sends(effects, "c-host")).toEqual([
        { t: "access-request", user: who.user, email: who.email },
      ]);
    }

    const overflow = {
      user: "u-pending-overflow",
      email: "pending-overflow@example.com",
      hostToken: false,
    };
    const rejected = core.connect("c-pending-overflow", overflow, T0 + 1);
    expectCapacityRejection(rejected, "c-pending-overflow", "too_many_pending");

    const reconnected = core.connect("c-host-2", HOST, T0 + 2);
    const resurfaced = sends(reconnected, "c-host-2").filter((m) => m.t === "access-request");
    expect(resurfaced).toHaveLength(MAX_PENDING_REQUESTS_PER_SESSION);
    expect(resurfaced).not.toContainEqual({
      t: "access-request",
      user: overflow.user,
      email: overflow.email,
    });

    core.disconnect(pending[0]!.conn, T0 + 3);
    const retry = core.connect("c-pending-overflow-retry", overflow, T0 + 4);
    expect(sends(retry, "c-pending-overflow-retry")).toEqual([{ t: "access-pending" }]);
    expect(sends(retry, "c-host-2")).toEqual([
      { t: "access-request", user: overflow.user, email: overflow.email },
    ]);
  });
});

describe("roles and moderation", () => {
  it("viewer input is dropped; editor input reaches the host", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "viewer");
    const dropped = core.handleGuest("c-alice", {
      t: "input",
      ws: "workspace:1",
      pane: "surface:1",
      data: "ls\n",
    });
    expect(dropped).toEqual([]);
    core.handleHost("c-host", { t: "role", user: ALICE.user, role: "editor" });
    const relayed = core.handleGuest("c-alice", {
      t: "input",
      ws: "workspace:1",
      pane: "surface:1",
      data: "ls\n",
    });
    expect(sends(relayed, "c-host")).toEqual([
      { t: "guest-input", user: ALICE.user, ws: "workspace:1", pane: "surface:1", data: "ls\n" },
    ]);
  });

  it("input to an unshared workspace never reaches the host", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    const effects = core.handleGuest("c-alice", {
      t: "input",
      ws: "workspace:99",
      pane: "surface:1",
      data: "rm -rf /\n",
    });
    expect(effects).toEqual([]);
  });

  it("relays input only to the exact current terminal leaf", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");

    expect(
      core.handleGuest("c-alice", {
        t: "input",
        ws: "workspace:1",
        pane: "surface:stale",
        data: "x",
      }),
    ).toEqual([]);

    core.handleHost("c-host", {
      t: "layout",
      layout: {
        ws: "workspace:1",
        tree: {
          kind: "split",
          axis: "h",
          ratio: 0.5,
          a: { kind: "pane", pane: "surface:1", content: "browser" },
          b: { kind: "pane", pane: "surface:2", content: "terminal", cols: 80, rows: 24 },
        },
      },
    });

    expect(
      core.handleGuest("c-alice", {
        t: "input",
        ws: "workspace:1",
        pane: "surface:1",
        data: "x",
      }),
    ).toEqual([]);
    expect(sends(
      core.handleGuest("c-alice", {
        t: "input",
        ws: "workspace:1",
        pane: "surface:2",
        data: "x",
      }),
      "c-host",
    )).toContainEqual({
      t: "guest-input",
      user: ALICE.user,
      ws: "workspace:1",
      pane: "surface:2",
      data: "x",
    });
  });

  it("drops terminal input beyond the UTF-8 byte limit", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    expect(
      core.handleGuest("c-alice", {
        t: "input",
        ws: "workspace:1",
        pane: "surface:1",
        data: "界".repeat(Math.ceil(MAX_TERMINAL_INPUT_BYTES / 3) + 1),
      }),
    ).toEqual([]);
  });

  it("role change notifies the guest", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    const effects = core.handleHost("c-host", { t: "role", user: ALICE.user, role: "viewer" });
    expect(sends(effects, "c-alice")).toContainEqual({ t: "role-changed", role: "viewer" });
  });

  it("kick closes with a kicked message and blocks rejoin", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const effects = core.handleHost("c-host", { t: "kick", user: ALICE.user });
    expect(sends(effects, "c-alice")).toContainEqual({ t: "kicked" });
    expect(closes(effects)).toContainEqual({ to: "c-alice", code: 4003 });
    const retry = core.connect("c-alice2", ALICE, T0 + 5000);
    expect(sends(retry, "c-alice2")).toContainEqual({ t: "access-denied" });
  });

  it("guests connecting after an approval reuse their grant and color", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    approveGuest(core, "c-bob", BOB);
    core.disconnect("c-alice", T0);
    const effects = core.connect("c-alice2", ALICE, T0);
    const snapshot = sends(effects, "c-alice2").find((m) => m.t === "session-state");
    if (snapshot?.t === "session-state") {
      expect(snapshot.you.color).toBe(1);
      const bob = snapshot.participants.find((p) => p.user === BOB.user);
      expect(bob?.color).toBe(2);
    } else {
      throw new Error("expected snapshot");
    }
  });

  it("bounds persisted grant and deny collections", () => {
    const core = bootedCore();
    for (let i = 0; i < MAX_GRANTS_PER_SESSION + 5; i += 1) {
      core.handleHost("c-host", { t: "approve", user: `u-grant-${i}`, role: "viewer" });
    }
    for (let i = 0; i < MAX_DENIED_PER_SESSION + 5; i += 1) {
      core.handleHost("c-host", { t: "deny", user: `u-denied-${i}` });
    }
    expect(core.persisted.grants).toHaveLength(MAX_GRANTS_PER_SESSION);
    expect(core.persisted.denied).toHaveLength(MAX_DENIED_PER_SESSION);
  });
});

describe("cursors, chat, presence", () => {
  it("cursor broadcasts to everyone else; unshared workspaces are scrubbed", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const pos = { ws: "workspace:1", pane: "surface:1", x: 0.5, y: 0.5 };
    const effects = core.handleGuest("c-alice", { t: "cursor", pos });
    expect(sends(effects, "c-host")).toContainEqual({ t: "cursor", user: ALICE.user, pos });
    expect(sends(effects, "c-alice")).toEqual([]);
    const offGrid = core.handleGuest("c-alice", {
      t: "cursor",
      pos: { ws: "workspace:9", pane: "surface:1", x: 0.5, y: 0.5 },
    });
    expect(sends(offGrid, "c-host")).toContainEqual({ t: "cursor", user: ALICE.user, pos: null });
  });

  it("scrubs non-terminal and non-finite cursor positions", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleHost("c-host", {
      t: "layout",
      layout: {
        ws: "workspace:1",
        tree: {
          kind: "split",
          axis: "v",
          ratio: 0.5,
          a: { kind: "pane", pane: "surface:1", content: "terminal" },
          b: { kind: "pane", pane: "surface:web", content: "browser" },
        },
      },
    });
    for (const pos of [
      { ws: "workspace:1", pane: "surface:web", x: 0.5, y: 0.5 },
      { ws: "workspace:1", pane: "surface:1", x: Number.NaN, y: 0.5 },
      { ws: "workspace:1", pane: "surface:1", x: -0.1, y: 0.5 },
    ]) {
      expect(
        sends(core.handleGuest("c-alice", { t: "cursor", pos }, T0), "c-host"),
      ).toContainEqual({ t: "cursor", user: ALICE.user, pos: null });
    }
  });

  it("enforces a bounded per-socket cursor rate window", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const pos = { ws: "workspace:1", pane: "surface:1", x: 0.5, y: 0.5 };
    for (let i = 0; i < CURSOR_RATE_LIMIT; i += 1) {
      expect(core.handleGuest("c-alice", { t: "cursor", pos }, T0)).not.toEqual([]);
    }
    const excess = core.handleGuest("c-alice", { t: "cursor", pos }, T0);
    expect(sends(excess)).toEqual([]);
    expect(excess).toContainEqual({
      kind: "setAlarm",
      at: T0 + CURSOR_RATE_WINDOW_MS,
    });
    // No later cursor input is needed: the shared alarm emits the coalesced
    // latest position exactly at the next window boundary.
    expect(
      sends(core.alarm(T0 + CURSOR_RATE_WINDOW_MS), "c-host"),
    ).toContainEqual({ t: "cursor", user: ALICE.user, pos });
  });

  it("chat is persisted, capped, and broadcast to active participants only", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.connect("c-bob", BOB, T0); // pending, must not receive chat
    const effects = core.handleGuest("c-alice", { t: "chat", text: "hello" });
    expect(sends(effects, "c-host").some((m) => m.t === "chat")).toBe(true);
    expect(sends(effects, "c-bob")).toEqual([]);
    for (let i = 0; i < CHAT_HISTORY_LIMIT + 25; i += 1) {
      core.handleGuest(
        "c-alice",
        { t: "chat", text: `m${i}` },
        T0 + (i + 1) * 1_000,
      );
    }
    expect(core.persisted.chat.length).toBe(CHAT_HISTORY_LIMIT);
    expect(core.persisted.chat.at(-1)?.text).toBe(`m${CHAT_HISTORY_LIMIT + 24}`);
  });

  it("blank chat is ignored", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    expect(core.handleGuest("c-alice", { t: "chat", text: "   " })).toEqual([]);
  });

  it("bounds oversized chat in persisted and broadcast state", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const effects = core.handleGuest("c-alice", {
      t: "chat",
      text: "x".repeat(CHAT_TEXT_LIMIT + 100),
    });

    expect(core.persisted.chat.at(-1)?.text).toHaveLength(CHAT_TEXT_LIMIT);
    for (const broadcast of sends(effects).filter((m) => m.t === "chat")) {
      if (broadcast.t !== "chat") throw new Error("expected chat broadcast");
      expect(broadcast.msg.text).toHaveLength(CHAT_TEXT_LIMIT);
    }
  });

  it("bounds serialized persisted chat bytes as well as count", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    for (let i = 0; i < CHAT_HISTORY_LIMIT; i += 1) {
      core.handleGuest(
        "c-alice",
        { t: "chat", text: `${i}:${"x".repeat(3_900)}` },
        T0 + (i + 1) * 1_000,
      );
    }
    const bytes = new TextEncoder().encode(JSON.stringify(core.persisted.chat)).byteLength;
    expect(core.persisted.chat.length).toBeLessThan(CHAT_HISTORY_LIMIT);
    expect(bytes).toBeLessThanOrEqual(CHAT_HISTORY_BYTE_LIMIT + 2);
  });

  it("scrubs an unshared chat bubble before persisting and broadcasting it", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const effects = core.handleGuest("c-alice", {
      t: "chat",
      text: "look here",
      bubble: { ws: "workspace:private", pane: "surface:secret", x: 0.5, y: 0.5 },
    });

    const persisted = core.persisted.chat.at(-1);
    expect(persisted?.text).toBe("look here");
    expect(persisted).not.toHaveProperty("bubble");

    const broadcasts = sends(effects).filter((m) => m.t === "chat");
    expect(broadcasts).toHaveLength(2);
    for (const broadcast of broadcasts) {
      if (broadcast.t !== "chat") throw new Error("expected chat broadcast");
      expect(broadcast.msg).not.toHaveProperty("bubble");
    }
  });

  it("keeps chat bubbles only on a current terminal with normalized finite coords", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleHost("c-host", {
      t: "layout",
      layout: {
        ws: "workspace:1",
        tree: {
          kind: "split",
          axis: "h",
          ratio: 0.5,
          a: { kind: "pane", pane: "surface:1", content: "terminal" },
          b: { kind: "pane", pane: "surface:web", content: "browser" },
        },
      },
    });
    const valid = core.handleGuest("c-alice", {
      t: "chat",
      text: "terminal",
      bubble: { ws: "workspace:1", pane: "surface:1", x: 0, y: 1 },
    });
    expect(sends(valid, "c-host").find((message) => message.t === "chat")).toHaveProperty(
      "msg.bubble",
    );
    for (const [index, bubble] of [
      { ws: "workspace:1", pane: "surface:web", x: 0.5, y: 0.5 },
      { ws: "workspace:1", pane: "surface:1", x: Number.POSITIVE_INFINITY, y: 0.5 },
      { ws: "workspace:1", pane: "surface:1", x: 1.1, y: 0.5 },
    ].entries()) {
      const effects = core.handleGuest(
        "c-alice",
        { t: "chat", text: "scrub", bubble },
        T0 + (index + 1) * 1_000,
      );
      const chat = sends(effects, "c-host").find((message) => message.t === "chat");
      if (chat?.t !== "chat") throw new Error("expected chat");
      expect(chat.msg).not.toHaveProperty("bubble");
      expect(core.persisted.chat.at(-1)).not.toHaveProperty("bubble");
    }
  });

  it("focus updates flow into presence participants", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const effects = core.handleGuest("c-alice", { t: "focus", ws: "workspace:1" });
    const presence = sends(effects, "c-host").find((m) => m.t === "presence");
    if (presence?.t === "presence") {
      const alice = presence.participants.find((p) => p.user === ALICE.user);
      expect(alice?.focusWs).toBe("workspace:1");
    } else {
      throw new Error("expected presence");
    }
  });
});

describe("subscriptions and binary routing", () => {
  it("sub/unsub report counts to the host and route grid frames", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    approveGuest(core, "c-bob", BOB);
    const subEffects = core.handleGuest("c-alice", {
      t: "sub",
      ws: "workspace:1",
      pane: "surface:1",
    });
    expect(sends(subEffects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 1,
    });
    const frame = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "workspace:1",
      "surface:1",
      new TextEncoder().encode("{}"),
    );
    const routed = core.routeBinary("c-host", "workspace:1", "surface:1", frame);
    const targets = routed
      .filter((e): e is Extract<Effect, { kind: "sendBinary" }> => e.kind === "sendBinary")
      .map((e) => e.to);
    expect(targets).toEqual(["c-alice"]);
    const unsubEffects = core.handleGuest("c-alice", {
      t: "unsub",
      ws: "workspace:1",
      pane: "surface:1",
    });
    expect(sends(unsubEffects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 0,
    });
  });

  it("a subscriber's disconnect reports the dropped count to the host", () => {
    // Regression: without this, the host's streamer count stays stale and a
    // rejoining guest gets a delta as its first frame (blank pane).
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" });
    const effects = core.disconnect("c-alice", T0 + 5_000);
    expect(sends(effects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 0,
    });
  });

  it("deny of a subscribed guest also reports dropped counts", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" });
    const effects = core.handleHost("c-host", { t: "deny", user: ALICE.user });
    expect(sends(effects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 0,
    });
  });

  it("unsharing a workspace drops its subs, notifies the host, and stops routing", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" });
    const effects = core.handleHost("c-host", { t: "shared", shared: [] });
    expect(sends(effects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 0,
    });
    // A lagging host still emitting frames for the unshared workspace gets dropped.
    expect(core.routeBinary("c-host", "workspace:1", "surface:1", new Uint8Array(8))).toEqual([]);
  });

  it("layout churn drops stale or non-terminal subscriptions and frames", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" });
    const effects = core.handleHost("c-host", {
      t: "layout",
      layout: {
        ws: "workspace:1",
        tree: { kind: "pane", pane: "surface:1", content: "browser" },
      },
    });
    expect(sends(effects, "c-host")).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 0,
    });
    expect(
      core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" }),
    ).toEqual([]);
    expect(
      core.routeBinary("c-host", "workspace:1", "surface:1", new Uint8Array(8)),
    ).toEqual([]);
  });

  it("caps per-connection subscriptions", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleHost("c-host", {
      t: "layout",
      layout: { ws: "workspace:1", tree: terminalTree(65) },
    });
    for (let i = 0; i < 64; i += 1) {
      core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: `surface:${i}` });
    }
    const over = core.handleGuest("c-alice", {
      t: "sub",
      ws: "workspace:1",
      pane: "surface:64",
    });
    expect(sends(over, "c-alice")).toContainEqual({
      t: "error",
      code: "too_many_subs",
      message: "subscription limit reached",
    });
    // Re-subscribing an existing pane is idempotent and emits no host update.
    const resub = core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:0" });
    expect(resub).toEqual([]);
  });

  it("binary frames from guests are never routed", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    expect(core.routeBinary("c-alice", "workspace:1", "surface:1", new Uint8Array(4))).toEqual([]);
  });

  it("pixel-kind frames are outside v1", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:1" });
    expect(
      core.routeBinary("c-host", "workspace:1", "surface:1", new Uint8Array(4), 0x02),
    ).toEqual([]);
  });

  it("subs to unshared workspaces are refused", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    expect(
      core.handleGuest("c-alice", { t: "sub", ws: "workspace:9", pane: "surface:1" }),
    ).toEqual([]);
  });
});

describe("session lifecycle", () => {
  it("host end closes everyone and marks the session dead", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const endedAt = T0 + 1_000;
    const cleanupAt = endedAt + ENDED_TOMBSTONE_RETENTION_MS;
    const effects = core.handleHost("c-host", { t: "end" }, endedAt);
    expect(sends(effects, "c-alice")).toContainEqual({
      t: "session-ended",
      reason: "host-stopped",
    });
    expect(ENDED_TOMBSTONE_RETENTION_MS).toBeGreaterThan(300_000);
    expect(core.persisted.endedAt).toBe(endedAt);
    expect(effects).toContainEqual({ kind: "setAlarm", at: cleanupAt });
    expect(effects.some((effect) => effect.kind === "deleteAllStorage")).toBe(false);
    expect(core.ended).toBe(true);
    const late = core.connect("c-bob", BOB, endedAt + 1);
    expect(sends(late, "c-bob")).toContainEqual({ t: "session-ended", reason: "host-stopped" });

    const earlyCleanup = core.alarm(cleanupAt - 1);
    expect(earlyCleanup).toContainEqual({ kind: "setAlarm", at: cleanupAt });
    expect(earlyCleanup.some((effect) => effect.kind === "deleteAllStorage")).toBe(false);
    expect(core.alarm(Number.NaN)).toEqual([{ kind: "setAlarm", at: cleanupAt }]);
    expect(core.alarm(cleanupAt)).toEqual([{ kind: "deleteAllStorage" }]);
  });

  it("host disconnect arms the grace alarm; alarm past grace ends the session", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const dis = core.disconnect("c-host", T0 + 1000);
    const alarm = dis.find((e): e is Extract<Effect, { kind: "setAlarm" }> => e.kind === "setAlarm");
    expect(alarm?.at).toBe(T0 + 1000 + HOST_GRACE_MS);
    // Early alarm: re-arm, session still alive.
    const early = core.alarm(T0 + 1000 + HOST_GRACE_MS / 2);
    expect(early.some((e) => e.kind === "setAlarm")).toBe(true);
    expect(core.ended).toBe(false);
    // Host returns within grace: nothing ends.
    core.connect("c-host2", HOST, T0 + 2000);
    expect(core.alarm(T0 + 10 + HOST_GRACE_MS)).toEqual([]);
    // Host leaves again and the grace elapses.
    core.disconnect("c-host2", T0 + 3000);
    const endedAt = T0 + 3000 + HOST_GRACE_MS;
    const ended = core.alarm(endedAt);
    expect(sends(ended, "c-alice")).toContainEqual({ t: "session-ended", reason: "host-gone" });
    expect(core.persisted.endedAt).toBe(endedAt);
    expect(ended).toContainEqual({
      kind: "setAlarm",
      at: endedAt + ENDED_TOMBSTONE_RETENTION_MS,
    });
    expect(ended.some((effect) => effect.kind === "deleteAllStorage")).toBe(false);
    expect(core.ended).toBe(true);
  });

  it("cursor boundary alarms re-arm the later host-grace deadline", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const pos = { ws: "workspace:1", pane: "surface:1", x: 0.5, y: 0.5 };
    for (let index = 0; index <= CURSOR_RATE_LIMIT; index += 1) {
      core.handleGuest("c-alice", { t: "cursor", pos }, T0);
    }
    core.disconnect("c-host", T0 + 100);
    const cursorAlarm = core.alarm(T0 + CURSOR_RATE_WINDOW_MS);
    expect(cursorAlarm).toContainEqual({
      kind: "setAlarm",
      at: T0 + 100 + HOST_GRACE_MS,
    });
    const ended = core.alarm(T0 + 100 + HOST_GRACE_MS);
    expect(sends(ended, "c-alice")).toContainEqual({
      t: "session-ended",
      reason: "host-gone",
    });
  });

  it("host stop replaces a pending cursor alarm with tombstone cleanup", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const pos = { ws: "workspace:1", pane: "surface:1", x: 0.5, y: 0.5 };
    for (let index = 0; index <= CURSOR_RATE_LIMIT; index += 1) {
      core.handleGuest("c-alice", { t: "cursor", pos }, T0);
    }
    const endedAt = T0 + 100;
    const cleanupAt = endedAt + ENDED_TOMBSTONE_RETENTION_MS;
    expect(core.handleHost("c-host", { t: "end" }, endedAt)).toContainEqual({
      kind: "setAlarm",
      at: cleanupAt,
    });
    const staleCursorAlarm = core.alarm(T0 + CURSOR_RATE_WINDOW_MS);
    expect(staleCursorAlarm).toEqual([{ kind: "setAlarm", at: cleanupAt }]);
    expect(sends(staleCursorAlarm).some((message) => message.t === "cursor")).toBe(false);
  });

  it("restore re-registers survivors, host first, and asks for resync", () => {
    const persisted = ShareSessionCore.create("code123", HOST, T0);
    let core = new ShareSessionCore(persisted);
    core.connect("c-host", HOST, T0);
    core.handleHost("c-host", {
      t: "hello",
      proto: PROTO_VERSION,
      shared: [{ id: "workspace:1", title: "main" }],
      layouts: [],
    });
    core.connect("c-alice", ALICE, T0);
    core.handleHost("c-host", { t: "approve", user: ALICE.user, role: "editor" });

    // Simulate eviction: rebuild from persisted state only.
    core = new ShareSessionCore(core.persisted);
    const effects = core.restore(
      [
        { id: "c-alice", ...ALICE },
        { id: "c-host", ...HOST },
      ],
      T0 + 60_000,
    );
    // Guest was already granted, so restore yields snapshots, not an ask.
    expect(sends(effects, "c-host").some((m) => m.t === "access-request")).toBe(false);
    expect(sends(effects, "c-alice").some((m) => m.t === "session-state")).toBe(true);
    expect(sends(effects, "c-alice")).toContainEqual({ t: "resync" });
    expect(sends(effects, "c-host")).toContainEqual({ t: "resync" });
  });

  it("restores an ended tombstone, re-arms cleanup, and deletes only at the boundary", () => {
    const endedAt = T0 + 1_000;
    const cleanupAt = endedAt + ENDED_TOMBSTONE_RETENTION_MS;
    const beforeEviction = bootedCore();
    beforeEviction.handleHost("c-host", { t: "end" }, endedAt);
    const persisted = restorePersistedSession(structuredClone(beforeEviction.persisted));
    expect(persisted?.endedAt).toBe(endedAt);
    if (!persisted) throw new Error("failed to restore tombstone");

    const afterEviction = new ShareSessionCore(persisted);
    const restored = afterEviction.restore(
      [{ id: "c-host-restored", ...HOST }],
      cleanupAt - 1,
    );
    expect(restored).toContainEqual({ kind: "setAlarm", at: cleanupAt });
    expect(sends(restored, "c-host-restored")).toContainEqual({
      t: "session-ended",
      reason: "host-stopped",
    });
    expect(restored.some((effect) => effect.kind === "deleteAllStorage")).toBe(false);
    expect(afterEviction.alarm(cleanupAt - 1)).toContainEqual({
      kind: "setAlarm",
      at: cleanupAt,
    });
    expect(afterEviction.alarm(cleanupAt)).toEqual([{ kind: "deleteAllStorage" }]);
  });

  it("fails closed on inconsistent tombstone timestamps", () => {
    const active = ShareSessionCore.create("code123", HOST, T0);
    expect(restorePersistedSession({ ...active, endedAt: T0 })).toBeNull();
    expect(
      restorePersistedSession({
        ...active,
        ended: "host-stopped",
        endedAt: null,
      }),
    ).toBeNull();
    expect(
      restorePersistedSession({
        ...active,
        ended: "host-gone",
        endedAt: T0 - 1,
      }),
    ).toBeNull();
    const unboundedLegacy = {
      ...ShareSessionCore.create("code123", HOST, Number.MAX_VALUE),
      ended: "host-stopped" as const,
      hostDisconnectedAt: null,
    } as Record<string, unknown>;
    delete unboundedLegacy.endedAt;
    expect(restorePersistedSession(unboundedLegacy)).toBeNull();
  });

  it("restores legacy tombstones with a deterministic token-safe deadline", () => {
    const legacy = {
      ...ShareSessionCore.create("code123", HOST, T0),
      ended: "host-stopped" as const,
      hostDisconnectedAt: null,
    } as Record<string, unknown>;
    delete legacy.endedAt;
    const restored = restorePersistedSession(legacy);
    expect(restored?.endedAt).toBe(T0);
    if (!restored) throw new Error("failed to restore legacy tombstone");

    const core = new ShareSessionCore(restored);
    expect(core.restore([], T0 + 1)).toContainEqual({
      kind: "setAlarm",
      at: T0 + ENDED_TOMBSTONE_RETENTION_MS,
    });
  });

  it("restores max grants and 32 survivors with two sends per active target", () => {
    const persisted = worstCasePersistedSession();
    const core = new ShareSessionCore(persisted);
    const survivors = [
      {
        id: "c-max-host",
        user: persisted.host.user,
        email: persisted.host.email,
        hostToken: true,
      },
      ...persisted.grants.slice(0, 31).map((grant, index) => ({
        id: `c-survivor-${index}`,
        user: grant.user,
        email: grant.email,
        hostToken: false,
      })),
    ];
    const effects = core.restore(survivors, T0 + 60_000);
    const outbound = effects.filter(
      (effect): effect is Extract<Effect, { kind: "send" }> => effect.kind === "send",
    );
    expect(outbound).toHaveLength(survivors.length * 2);
    expect(outbound.some((effect) => effect.msg.t === "presence")).toBe(false);

    const nonce = "00000000-0000-4000-8000-000000000001";
    for (const survivor of survivors) {
      const targeted = outbound.filter((effect) => effect.to === survivor.id);
      expect(targeted.map((effect) => effect.msg.t)).toEqual([
        "session-state",
        "resync",
      ]);
      const snapshot = targeted[0]?.msg;
      if (snapshot?.t !== "session-state") throw new Error("missing restore snapshot");
      expect(snapshot.participants).toHaveLength(MAX_GRANTS_PER_SESSION + 1);
      const prospectiveCredit = targeted.reduce(
        (total, effect) =>
          total +
          deliveryCreditBytes(
            new TextEncoder().encode(JSON.stringify(effect.msg)).byteLength,
            nonce,
          ),
        0,
      );
      expect(prospectiveCredit).toBeLessThan(MAX_SOCKET_OUTSTANDING_BYTES);
    }
  });

  it("restores a pending survivor with one pending and one host request path", () => {
    const persisted = ShareSessionCore.create("code123", HOST, T0);
    const core = new ShareSessionCore(persisted);
    const effects = core.restore(
      [
        { id: "c-host", ...HOST },
        { id: "c-pending", ...ALICE },
      ],
      T0 + 1_000,
    );
    expect(sends(effects, "c-pending")).toEqual([{ t: "access-pending" }]);
    expect(sends(effects, "c-host").filter((message) => message.t === "access-request")).toEqual([
      { t: "access-request", user: ALICE.user, email: ALICE.email },
    ]);
    expect(sends(effects).some((message) => message.t === "presence")).toBe(false);
  });

  it("fails closed on malformed persisted state", () => {
    const persisted = ShareSessionCore.create("code123", HOST, T0);
    expect(
      restorePersistedSession({
        ...persisted,
        host: { user: 42, email: HOST.email },
      }),
    ).toBeNull();
    expect(
      restorePersistedSession({
        ...persisted,
        layouts: [
          {
            ws: "private-workspace",
            tree: { kind: "pane", pane: "surface:secret", content: "terminal" },
          },
        ],
      }),
    ).toBeNull();
  });

  it("bounds restored collections and scrubs stale chat bubbles", () => {
    const persisted = bootedCore().persisted;
    const restored = restorePersistedSession({
      ...persisted,
      grants: Array.from({ length: MAX_GRANTS_PER_SESSION + 20 }, (_, i) => ({
        user: `u-${i}`,
        email: "",
        role: "viewer",
        color: i % 8,
      })),
      denied: Array.from({ length: MAX_DENIED_PER_SESSION + 20 }, (_, i) => `u-denied-${i}`),
      chat: [
        {
          id: "chat-1",
          user: HOST.user,
          text: "old anchor",
          ts: T0,
          bubble: { ws: "workspace:1", pane: "surface:stale", x: 0.5, y: 0.5 },
        },
      ],
    });
    expect(restored).not.toBeNull();
    expect(restored?.grants).toHaveLength(MAX_GRANTS_PER_SESSION);
    expect(restored?.denied).toHaveLength(MAX_DENIED_PER_SESSION);
    expect(restored?.chat[0]).not.toHaveProperty("bubble");
  });
});

describe("application rate budgets", () => {
  it("accepts chat 2/socket/s, emits one bounded error, and resets at one second", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const first = core.handleGuest("c-alice", { t: "chat", text: "one" }, T0);
    const second = core.handleGuest("c-alice", { t: "chat", text: "two" }, T0);
    const third = core.handleGuest("c-alice", { t: "chat", text: "three" }, T0);
    const fourth = core.handleGuest("c-alice", { t: "chat", text: "four" }, T0);
    expect(sends(first, "c-host").filter((message) => message.t === "chat")).toHaveLength(1);
    expect(sends(second, "c-host").filter((message) => message.t === "chat")).toHaveLength(1);
    expect(sends(third, "c-alice")).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit exceeded" },
    ]);
    expect(fourth).toEqual([]);
    expect(core.persisted.chat.map((message) => message.text)).toEqual(["one", "two"]);
    expect(
      sends(
        core.handleGuest("c-alice", { t: "chat", text: "reset" }, T0 + 1_000),
        "c-host",
      ).some((message) => message.t === "chat"),
    ).toBe(true);
  });

  it("accepts exactly 8 room chats with exact persistence/write/fanout", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 5 }, (_, index) => ({
      id: `c-chat-${index}`,
      identity: {
        user: `u-chat-${index}`,
        email: `chat-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) approveGuest(core, guest.id, guest.identity);
    const before = core.persisted.chat.length;
    const acceptedEffects: Effect[] = [];
    for (const guest of guests.slice(0, 4)) {
      for (let index = 0; index < CHAT_RATE_LIMIT_PER_SOCKET; index += 1) {
        acceptedEffects.push(
          ...core.handleGuest(
            guest.id,
            { t: "chat", text: `${guest.id}-${index}` },
            T0,
          ),
        );
      }
    }
    expect(core.persisted.chat.length - before).toBe(CHAT_RATE_LIMIT_PER_ROOM);
    expect(acceptedEffects.filter((effect) => effect.kind === "persist")).toHaveLength(
      CHAT_RATE_LIMIT_PER_ROOM,
    );
    const activeConnections = 1 + guests.length;
    expect(
      acceptedEffects.filter(
        (effect) => effect.kind === "send" && effect.msg.t === "chat",
      ),
    ).toHaveLength(CHAT_RATE_LIMIT_PER_ROOM * activeConnections);

    const rejected = core.handleGuest(
      guests[4]!.id,
      { t: "chat", text: "room ninth" },
      T0,
    );
    expect(sends(rejected, guests[4]!.id)).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit exceeded" },
    ]);
    expect(core.persisted.chat.length - before).toBe(CHAT_RATE_LIMIT_PER_ROOM);
    expect(
      sends(
        core.handleGuest(
          guests[4]!.id,
          { t: "chat", text: "room reset" },
          T0 + 1_000,
        ),
      ).some((message) => message.t === "chat"),
    ).toBe(true);
  });

  it("relays 60 ordered inputs/socket, closes on 61, and resets at one second", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    const relayed: string[] = [];
    for (let index = 0; index < INPUT_RATE_LIMIT_PER_SOCKET; index += 1) {
      const effects = core.handleGuest(
        "c-alice",
        { t: "input", ws: "workspace:1", pane: "surface:1", data: `${index}\n` },
        T0,
      );
      const message = sends(effects, "c-host")[0];
      if (message?.t !== "guest-input") throw new Error("expected relayed input");
      relayed.push(message.data);
    }
    expect(relayed).toEqual(
      Array.from({ length: INPUT_RATE_LIMIT_PER_SOCKET }, (_, index) => `${index}\n`),
    );
    expect(
      closes(
        core.handleGuest(
          "c-alice",
          { t: "input", ws: "workspace:1", pane: "surface:1", data: "61\n" },
          T0,
        ),
      ),
    ).toEqual([{ to: "c-alice", code: RATE_LIMIT_CLOSE_CODE }]);
    expect(
      sends(
        core.handleGuest(
          "c-alice",
          { t: "input", ws: "workspace:1", pane: "surface:1", data: "reset\n" },
          T0 + 1_000,
        ),
        "c-host",
      )[0],
    ).toHaveProperty("data", "reset\n");
  });

  it("accepts 240 room inputs and rejects 241 without closing a healthy peer", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 5 }, (_, index) => ({
      id: `c-input-${index}`,
      identity: {
        user: `u-input-${index}`,
        email: `input-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) approveGuest(core, guest.id, guest.identity);
    let accepted = 0;
    for (const guest of guests.slice(0, 4)) {
      for (let index = 0; index < INPUT_RATE_LIMIT_PER_SOCKET; index += 1) {
        const effects = core.handleGuest(
          guest.id,
          { t: "input", ws: "workspace:1", pane: "surface:1", data: `${accepted}\n` },
          T0,
        );
        accepted += sends(effects, "c-host").filter(
          (message) => message.t === "guest-input",
        ).length;
      }
    }
    expect(accepted).toBe(INPUT_RATE_LIMIT_PER_ROOM);
    const rejected = core.handleGuest(
      guests[4]!.id,
      { t: "input", ws: "workspace:1", pane: "surface:1", data: "241\n" },
      T0,
    );
    expect(sends(rejected, "c-host")).toEqual([]);
    expect(closes(rejected)).toEqual([]);
    expect(sends(rejected, guests[4]!.id)).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit exceeded" },
    ]);
    expect(
      sends(
        core.handleGuest(
          guests[4]!.id,
          { t: "input", ws: "workspace:1", pane: "surface:1", data: "reset\n" },
          T0 + 1_000,
        ),
        "c-host",
      )[0],
    ).toHaveProperty("data", "reset\n");
  });

  it("counts 64 real sub mutations/socket, drops 65, and resets", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    for (let index = 0; index < SUB_RATE_LIMIT_PER_SOCKET; index += 1) {
      const effects =
        index % 2 === 0
          ? core.handleGuest(
              "c-alice",
              { t: "sub", ws: "workspace:1", pane: "surface:1" },
              T0,
            )
          : core.handleGuest(
              "c-alice",
              { t: "unsub", ws: "workspace:1", pane: "surface:1" },
              T0,
            );
      expect(sends(effects, "c-host")).toHaveLength(1);
    }
    const over = core.handleGuest(
      "c-alice",
      { t: "sub", ws: "workspace:1", pane: "surface:1" },
      T0,
    );
    expect(sends(over, "c-host")).toEqual([]);
    expect(sends(over, "c-alice")).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit exceeded" },
    ]);
    expect(
      sends(
        core.handleGuest(
          "c-alice",
          { t: "sub", ws: "workspace:1", pane: "surface:1" },
          T0 + 1_000,
        ),
        "c-host",
      ),
    ).toHaveLength(1);
  });

  it("accepts 256 room sub mutations and rejects 257 without host churn", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 5 }, (_, index) => ({
      id: `c-sub-${index}`,
      identity: {
        user: `u-sub-${index}`,
        email: `sub-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) approveGuest(core, guest.id, guest.identity);
    let hostUpdates = 0;
    for (const guest of guests.slice(0, 4)) {
      for (let index = 0; index < SUB_RATE_LIMIT_PER_SOCKET; index += 1) {
        const effects =
          index % 2 === 0
            ? core.handleGuest(
                guest.id,
                { t: "sub", ws: "workspace:1", pane: "surface:1" },
                T0,
              )
            : core.handleGuest(
                guest.id,
                { t: "unsub", ws: "workspace:1", pane: "surface:1" },
                T0,
              );
        hostUpdates += sends(effects, "c-host").length;
      }
    }
    expect(hostUpdates).toBe(SUB_RATE_LIMIT_PER_ROOM);
    const rejected = core.handleGuest(
      guests[4]!.id,
      { t: "sub", ws: "workspace:1", pane: "surface:1" },
      T0,
    );
    expect(sends(rejected, "c-host")).toEqual([]);
    expect(sends(rejected, guests[4]!.id)).toHaveLength(1);
    expect(
      sends(
        core.handleGuest(
          guests[4]!.id,
          { t: "sub", ws: "workspace:1", pane: "surface:1" },
          T0 + 1_000,
        ),
        "c-host",
      ),
    ).toHaveLength(1);
  });
});

describe("cursor room fairness", () => {
  it("bounds 32-socket load, coalesces latest, and drains every dirty sender fairly", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 31 }, (_, index) => ({
      id: `c-cursor-${index}`,
      identity: {
        user: `u-cursor-${index}`,
        email: `cursor-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) approveGuest(core, guest.id, guest.identity);
    const senders = [
      { id: "c-host", user: HOST.user, host: true },
      ...guests.map((guest) => ({ id: guest.id, user: guest.identity.user, host: false })),
    ];
    let firstWindowDeliveries = 0;
    for (const [senderIndex, sender] of senders.entries()) {
      for (let event = 0; event <= CURSOR_RATE_LIMIT; event += 1) {
        const pos = {
          ws: "workspace:1",
          pane: "surface:1",
          x: senderIndex / (senders.length - 1),
          y: event / CURSOR_RATE_LIMIT,
        };
        const effects = sender.host
          ? core.handleHost(sender.id, { t: "cursor", pos }, T0)
          : core.handleGuest(sender.id, { t: "cursor", pos }, T0);
        firstWindowDeliveries += effects.filter(
          (effect) => effect.kind === "send" && effect.msg.t === "cursor",
        ).length;
      }
    }
    const recipientsPerSource = senders.length - 1;
    expect(firstWindowDeliveries).toBeLessThanOrEqual(CURSOR_ROOM_DELIVERY_LIMIT);
    expect(firstWindowDeliveries / recipientsPerSource).toBeLessThanOrEqual(
      CURSOR_ROOM_SOURCE_LIMIT,
    );
    expect(core.rateLimitProfileSizes.connections).toBe(32);
    expect(core.rateLimitProfileSizes.dirtyCursors).toBeLessThanOrEqual(32);

    const trigger = senders.at(-1)!;
    // No new cursor event triggers this drain.
    const drained = core.alarm(T0 + CURSOR_RATE_WINDOW_MS);
    const cursorMessages = sends(drained).filter(
      (message): message is Extract<ServerMessage, { t: "cursor" }> =>
        message.t === "cursor",
    );
    const users = new Set(cursorMessages.map((message) => message.user));
    expect(users.size).toBe(32);
    expect(
      cursorMessages.find((message) => message.user === trigger.user)?.pos,
    ).toEqual({
      ws: "workspace:1",
      pane: "surface:1",
      x: 1,
      y: 1,
    });
    expect(
      cursorMessages.find((message) => message.user === HOST.user)?.pos?.y,
    ).toBe(1);
    expect(core.rateLimitProfileSizes.dirtyCursors).toBe(0);
  });
});

describe("maximum snapshot encoding", () => {
  it("keeps all 256 grants plus host in a valid snapshot below 1 MiB", () => {
    const persisted = worstCasePersistedSession();
    expect(persisted.grants).toHaveLength(MAX_GRANTS_PER_SESSION);
    const core = new ShareSessionCore(persisted);
    const effects = core.connect(
      "c-max-host",
      {
        user: persisted.host.user,
        email: persisted.host.email,
        hostToken: true,
      },
      T0,
    );
    const snapshot = sends(effects, "c-max-host").find(
      (message): message is Extract<ServerMessage, { t: "session-state" }> =>
        message.t === "session-state",
    );
    if (!snapshot) throw new Error("missing maximum snapshot");
    expect(snapshot.participants).toHaveLength(MAX_GRANTS_PER_SESSION + 1);
    expect(snapshot.layouts[0]?.tree).not.toBeNull();
    expect(new TextEncoder().encode(JSON.stringify(snapshot)).byteLength).toBeLessThan(
      MAX_SERVER_JSON_FRAME_BYTES,
    );
  });

  it("omits oldest snapshot chat deterministically without mutating history", () => {
    const persisted = ShareSessionCore.create("code123", HOST, T0);
    const core = new ShareSessionCore(persisted);
    persisted.chat.push(
      ...Array.from({ length: CHAT_HISTORY_LIMIT }, (_, index) => ({
        id: `chat-${index}`,
        user: HOST.user,
        text: `${index}:${"x".repeat(CHAT_TEXT_LIMIT - String(index).length - 1)}`,
        ts: T0 + index,
      })),
    );
    const effects = core.connect("c-host", HOST, T0);
    const snapshot = sends(effects, "c-host").find(
      (message): message is Extract<ServerMessage, { t: "session-state" }> =>
        message.t === "session-state",
    );
    if (!snapshot) throw new Error("missing trimmed snapshot");
    expect(new TextEncoder().encode(JSON.stringify(snapshot)).byteLength).toBeLessThan(
      MAX_SERVER_JSON_FRAME_BYTES,
    );
    expect(snapshot.chat.length).toBeLessThan(CHAT_HISTORY_LIMIT);
    expect(snapshot.chat[0]?.id).not.toBe("chat-0");
    expect(snapshot.chat.at(-1)?.id).toBe(`chat-${CHAT_HISTORY_LIMIT - 1}`);
    expect(persisted.chat).toHaveLength(CHAT_HISTORY_LIMIT);
    expect(persisted.chat[0]?.id).toBe("chat-0");
  });
});
