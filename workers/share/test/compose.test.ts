import { describe, expect, it } from "bun:test";

import { PROTO_VERSION } from "../src/protocol";
import type { ServerMessage } from "../src/protocol";
import { ShareSessionCore } from "../src/session";
import type { Effect } from "../src/session";

const T0 = 1_700_000_000_000;
const HOST = { user: "u-host", email: "host@cmux.com", hostToken: true };
const ALICE = { user: "u-alice", email: "alice@example.com", hostToken: false };

function sends(effects: Effect[], to?: string): ServerMessage[] {
  return effects
    .filter((e): e is Extract<Effect, { kind: "send" }> => e.kind === "send")
    .filter((e) => to === undefined || e.to === to)
    .map((e) => e.msg);
}

function bootedWithGuest(role: "editor" | "viewer"): ShareSessionCore {
  const core = new ShareSessionCore(
    ShareSessionCore.create("code123", { user: HOST.user, email: HOST.email }, T0),
  );
  core.connect("c-host", HOST, T0);
  core.handleHost("c-host", {
    t: "hello",
    proto: PROTO_VERSION,
    shared: [{ id: "workspace:1", title: "main" }],
    layouts: [],
  });
  core.connect("c-alice", ALICE, T0);
  core.handleHost("c-host", { t: "approve", user: ALICE.user, role });
  return core;
}

describe("multiplayer composer relay", () => {
  it("relays editor compose ops to the host with the sender attached", () => {
    const core = bootedWithGuest("editor");
    const effects = core.handleGuest("c-alice", {
      t: "compose",
      field: "pane-uuid",
      rev: 7,
      ops: [{ p: 3, i: "hi" }],
      caret: { start: 5, end: 5 },
    });
    expect(sends(effects, "c-host")).toEqual([
      {
        t: "guest-compose",
        user: ALICE.user,
        field: "pane-uuid",
        rev: 7,
        ops: [{ p: 3, i: "hi" }],
        caret: { start: 5, end: 5 },
      },
    ]);
  });

  it("drops compose ops from viewers", () => {
    const core = bootedWithGuest("viewer");
    const effects = core.handleGuest("c-alice", {
      t: "compose",
      field: "pane-uuid",
      rev: 1,
      ops: [{ p: 0, i: "x" }],
    });
    expect(effects).toEqual([]);
  });

  it("host focus flows into presence so guests can follow the host", () => {
    const core = bootedWithGuest("editor");
    const effects = core.handleHost("c-host", { t: "focus", ws: "workspace:1" });
    const presence = sends(effects, "c-alice").find((m) => m.t === "presence");
    if (presence?.t === "presence") {
      expect(presence.participants.find((p) => p.isHost)?.focusWs).toBe("workspace:1");
    } else {
      throw new Error("expected presence broadcast");
    }
  });

  it("broadcasts host compose-state to active guests, not back to the host", () => {
    const core = bootedWithGuest("editor");
    const state = {
      t: "compose-state" as const,
      field: "pane-uuid",
      rev: 8,
      text: "hello",
      carets: [{ user: ALICE.user, start: 5, end: 5 }],
    };
    const effects = core.handleHost("c-host", state);
    expect(sends(effects, "c-alice")).toEqual([state]);
    expect(sends(effects, "c-host")).toEqual([]);
  });
});
