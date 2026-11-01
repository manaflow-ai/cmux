import { describe, expect, test } from "bun:test";
import { summarizeConnectors } from "./connectorState";

describe("summarizeConnectors", () => {
  test("labels the harness inventory as loaded instead of implying provider authorization", () => {
    expect(summarizeConnectors([{ status: "connected" }])).toEqual({
      kind: "loaded",
      count: 1,
    });
    expect(summarizeConnectors([{ status: "connected" }, { status: "connected" }])).toEqual({
      kind: "loaded",
      count: 2,
    });
  });

  test("surfaces reconnect before a loaded count", () => {
    expect(summarizeConnectors([{ status: "connected" }, { status: "failed" }, { status: "pending" }])).toEqual({
      kind: "reconnect",
      count: 1,
    });
  });

  test("surfaces pending servers while the harness is still loading", () => {
    expect(summarizeConnectors([{ status: "connected" }, { status: "pending" }])).toEqual({
      kind: "connecting",
      count: 1,
    });
  });
});
