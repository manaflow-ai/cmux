import { describe, expect, test } from "bun:test";
import { summarizeConnectors } from "./connectorState";

/// Every connect has lasted the shared bound; `QUIET`: none has yet.
const LASTED = (_key: string, down: boolean) => down;
const QUIET = () => false;
const named = (servers: { status: string }[]) => servers.map((server, i) => ({ name: `s${i}`, ...server }));

describe("summarizeConnectors", () => {
  test("labels the harness inventory as loaded instead of implying provider authorization", () => {
    expect(summarizeConnectors(named([{ status: "connected" }]), LASTED)).toEqual({
      kind: "loaded",
      count: 1,
    });
    expect(summarizeConnectors(named([{ status: "connected" }, { status: "connected" }]), LASTED)).toEqual({
      kind: "loaded",
      count: 2,
    });
  });

  test("surfaces reconnect before a loaded count", () => {
    expect(
      summarizeConnectors(named([{ status: "connected" }, { status: "failed" }, { status: "pending" }]), LASTED),
    ).toEqual({
      kind: "reconnect",
      count: 1,
    });
  });

  test("surfaces pending servers while the harness is still loading", () => {
    expect(summarizeConnectors(named([{ status: "connected" }, { status: "pending" }]), LASTED)).toEqual({
      kind: "connecting",
      count: 1,
    });
  });

  test("a connect that has not lasted the shared bound reads loaded; a failure still says so", () => {
    expect(summarizeConnectors(named([{ status: "connected" }, { status: "pending" }]), QUIET)).toEqual({
      kind: "loaded",
      count: 2,
    });
    expect(summarizeConnectors(named([{ status: "failed" }, { status: "pending" }]), QUIET)).toEqual({
      kind: "reconnect",
      count: 1,
    });
  });
});
