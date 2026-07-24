// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import { parseGuestMessage, parseHostMessage } from "../src/protocol";

describe("composer is outside protocol v1", () => {
  it("rejects guest composer edits", () => {
    expect(
      parseGuestMessage({
        t: "compose",
        field: "pane-uuid",
        rev: 7,
        ops: [{ p: 3, i: "hi" }],
        caret: { start: 5, end: 5 },
      }),
    ).toBeNull();
  });

  it("rejects host composer state", () => {
    expect(
      parseHostMessage({
        t: "compose-state",
        field: "pane-uuid",
        rev: 8,
        text: "hello",
        carets: [],
      }),
    ).toBeNull();
  });
});
