import { describe, expect, test } from "bun:test";
import { isAllowedAddress, isLoopback, parseClientMessage, Roster } from "../src/room.ts";

describe("room", () => {
  test("signals relay only between two different peers of the room", () => {
    const roster = new Roster();
    const ana = roster.join("ana", "mac");
    const bo = roster.join("bo", "mini");
    expect(roster.relayTarget(ana.id, bo.id)?.name).toBe("bo");
    expect(roster.relayTarget(ana.id, ana.id)).toBeUndefined();
    expect(roster.relayTarget("p99", bo.id)).toBeUndefined();
    roster.leave(bo.id);
    expect(roster.relayTarget(ana.id, bo.id)).toBeUndefined();
  });

  test("client messages are validated", () => {
    expect(parseClientMessage('{"t":"speech","text":"  "}')).toBeNull();
    expect(parseClientMessage('{"t":"pause","on":"yes"}')).toBeNull();
    expect(parseClientMessage("not json")).toBeNull();
    expect(parseClientMessage('{"t":"signal","to":"p2","data":{"candidate":1}}')).toEqual({ t: "signal", to: "p2", data: { candidate: 1 } });
    expect(parseClientMessage('{"t":"task.send","id":3}')).toEqual({ t: "task.send", id: 3 });
  });

  test("only loopback and tailnet addresses are allowed", () => {
    expect(isLoopback("::ffff:127.0.0.1")).toBe(true);
    expect(isAllowedAddress("100.82.214.112")).toBe(true);
    expect(isAllowedAddress("100.128.0.1")).toBe(false);
    expect(isAllowedAddress("192.168.1.4")).toBe(false);
    expect(isAllowedAddress("fd7a:115c:a1e0::1")).toBe(true);
  });
});
