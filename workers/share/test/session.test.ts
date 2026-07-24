import { describe, expect, it } from "bun:test";

import {
  BINARY_KIND_GRID,
  encodeBinaryHeader,
  PROTO_VERSION,
} from "../src/protocol";
import type { ServerMessage } from "../src/protocol";
import {
  CHAT_HISTORY_LIMIT,
  CHAT_TEXT_LIMIT,
  HOST_GRACE_MS,
  ShareSessionCore,
} from "../src/session";
import type { Effect } from "../src/session";

const T0 = 1_700_000_000_000;
const MAX_CONNECTIONS_PER_SESSION = 32;
const MAX_PENDING_REQUESTS_PER_SESSION = 16;
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

  it("chat is persisted, capped, and broadcast to active participants only", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    core.connect("c-bob", BOB, T0); // pending, must not receive chat
    const effects = core.handleGuest("c-alice", { t: "chat", text: "hello" });
    expect(sends(effects, "c-host").some((m) => m.t === "chat")).toBe(true);
    expect(sends(effects, "c-bob")).toEqual([]);
    for (let i = 0; i < CHAT_HISTORY_LIMIT + 25; i += 1) {
      core.handleGuest("c-alice", { t: "chat", text: `m${i}` });
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

  it("caps per-connection subscriptions", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    for (let i = 0; i < 64; i += 1) {
      core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: `surface:${i}` });
    }
    const over = core.handleGuest("c-alice", {
      t: "sub",
      ws: "workspace:1",
      pane: "surface:overflow",
    });
    expect(sends(over, "c-alice")).toContainEqual({
      t: "error",
      code: "too_many_subs",
      message: "subscription limit reached",
    });
    // Re-subscribing an existing pane is still allowed at the cap.
    const resub = core.handleGuest("c-alice", { t: "sub", ws: "workspace:1", pane: "surface:0" });
    expect(sends(resub, "c-host").some((m) => m.t === "guest-sub")).toBe(true);
  });

  it("binary frames from guests are never routed", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE);
    expect(core.routeBinary("c-alice", "workspace:1", "surface:1", new Uint8Array(4))).toEqual([]);
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
    const effects = core.handleHost("c-host", { t: "end" });
    expect(sends(effects, "c-alice")).toContainEqual({
      t: "session-ended",
      reason: "host-stopped",
    });
    expect(core.ended).toBe(true);
    const late = core.connect("c-bob", BOB, T0 + 1000);
    expect(sends(late, "c-bob")).toContainEqual({ t: "session-ended", reason: "host-stopped" });
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
    const ended = core.alarm(T0 + 3000 + HOST_GRACE_MS);
    expect(sends(ended, "c-alice")).toContainEqual({ t: "session-ended", reason: "host-gone" });
    expect(core.ended).toBe(true);
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
});
