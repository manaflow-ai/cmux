import { describe, expect, it } from "bun:test";

import { PROTO_VERSION } from "../src/protocol";
import type { GuestMessage, ServerMessage } from "../src/protocol";
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

const CLICK: GuestMessage = {
  t: "pointer",
  ws: "workspace:1",
  pane: "surface:9",
  action: "down",
  x: 0.5,
  y: 0.25,
  button: 0,
};

const KEY: GuestMessage = {
  t: "webkey",
  ws: "workspace:1",
  pane: "surface:9",
  key: "a",
  code: "KeyA",
  down: true,
};

describe("interactive browser pane relay (slice 3)", () => {
  it("relays editor pointer and key events to the host with the sender attached", () => {
    const core = bootedWithGuest("editor");
    expect(sends(core.handleGuest("c-alice", CLICK), "c-host")).toEqual([
      {
        t: "guest-pointer",
        user: ALICE.user,
        ws: "workspace:1",
        pane: "surface:9",
        action: "down",
        x: 0.5,
        y: 0.25,
        button: 0,
      },
    ]);
    expect(sends(core.handleGuest("c-alice", KEY), "c-host")).toEqual([
      {
        t: "guest-webkey",
        user: ALICE.user,
        ws: "workspace:1",
        pane: "surface:9",
        key: "a",
        code: "KeyA",
        down: true,
      },
    ]);
  });

  it("drops pointer/key events from viewers", () => {
    const core = bootedWithGuest("viewer");
    expect(core.handleGuest("c-alice", CLICK)).toEqual([]);
    expect(core.handleGuest("c-alice", KEY)).toEqual([]);
  });

  it("drops events aimed at unshared workspaces", () => {
    const core = bootedWithGuest("editor");
    expect(
      core.handleGuest("c-alice", { ...CLICK, ws: "workspace:99" } as GuestMessage),
    ).toEqual([]);
  });
});
