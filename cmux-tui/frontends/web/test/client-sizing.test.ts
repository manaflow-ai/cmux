import type { ClientInfo } from "cmux/raw";
import { describe, expect, it } from "vitest";
import { paneClientSummary } from "../src/lib/clientSizing";

function client(
  id: bigint,
  size: { cols: number; rows: number } | null,
  participating: boolean,
): ClientInfo {
  return {
    client: id,
    transport: "ws",
    name: null,
    kind: "web",
    connected_seconds: 1n,
    attached: [7n],
    sizes: [{
      surface: 7n,
      cols: size?.cols ?? null,
      rows: size?.rows ?? null,
      size_participating: participating,
    }],
    self: id === 1n,
  };
}

describe("paneClientSummary", () => {
  it("does not use excluded reports while an unsized attachment participates", () => {
    const clients = [
      client(1n, { cols: 120, rows: 30 }, false),
      client(2n, { cols: 80, rows: 40 }, false),
      client(3n, null, true),
    ];

    expect(paneClientSummary(clients, 7n)).toBeNull();
  });
});
