import type { ClientInfo } from "cmux/browser";
import { describe, expect, it } from "vitest";
import { paneClientSummary } from "../src/lib/clientSizing";

function client(
  id: number,
  size: { cols: number; rows: number } | null,
  participating: boolean,
): ClientInfo {
  return {
    client: id,
    transport: "ws",
    name: null,
    kind: "web",
    connected_seconds: 1,
    attached: [7],
    sizes: [{
      surface: 7,
      cols: size?.cols ?? null,
      rows: size?.rows ?? null,
      size_participating: participating,
    }],
    self: id === 1,
  };
}

describe("paneClientSummary", () => {
  it("does not use excluded reports while an unsized attachment participates", () => {
    const clients = [
      client(1, { cols: 120, rows: 30 }, false),
      client(2, { cols: 80, rows: 40 }, false),
      client(3, null, true),
    ];

    expect(paneClientSummary(clients, 7)).toBeNull();
  });
});
