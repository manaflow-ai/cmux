// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  BINARY_KIND_BASELINE,
  BINARY_KIND_OUTPUT,
  parseGuestMessage,
} from "../src/protocol";
import { ShareSessionCore } from "../src/session";

const T0 = 1_700_000_000_000;
const HOST = { user: "u-host", email: "host@cmux.com", hostToken: true };

describe("terminal-only v2 protocol", () => {
  it.each([
    {
      t: "pointer",
      ws: "workspace:1",
      pane: "surface:browser",
      action: "down",
      x: 0.5,
      y: 0.25,
    },
    {
      t: "webkey",
      ws: "workspace:1",
      pane: "surface:browser",
      key: "a",
      code: "KeyA",
      down: true,
    },
    { t: "follow", user: "u-host" },
  ])("rejects the unsupported guest verb $t", (message) => {
    expect(parseGuestMessage(message)).toBeNull();
  });

  it("does not route terminal data to a browser placeholder", () => {
    const core = new ShareSessionCore(
      ShareSessionCore.create("code123", { user: HOST.user, email: HOST.email }, T0),
    );
    core.connect("c-host", HOST, T0);
    core.handleHost("c-host", {
      t: "hello",
      proto: 2,
      shared: [{ id: "workspace:1", title: "main" }],
      layouts: [
        {
          ws: "workspace:1",
          tree: { kind: "pane", pane: "surface:browser", content: "browser" },
        },
      ],
    });

    expect(
      core.routeBinary(
        "c-host",
        "workspace:1",
        "surface:browser",
        new Uint8Array(8),
        BINARY_KIND_BASELINE,
      ),
    ).toEqual([]);
    expect(
      core.routeBinary(
        "c-host",
        "workspace:1",
        "surface:browser",
        new Uint8Array(8),
        BINARY_KIND_OUTPUT,
      ),
    ).toEqual([]);
  });
});
