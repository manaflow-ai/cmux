import { describe, expect, test } from "bun:test";
import type { Environment } from "./environments";
import { autoChoice, busyChoice, lastRemoteMachine, placementFromReply } from "./placement";

const mac: Environment = { id: "local", label: "leo-mac", kind: "local" };
const gcp: Environment = { id: "gcp-3", label: "gcp-3", kind: "ssh", state: "connected" };
const box: Environment = { id: "build-box", label: "build-box", kind: "ssh", state: "connected" };
const down: Environment = { id: "old-box", label: "old-box", kind: "ssh", state: "reconnecting" };
const cloud: Environment = { id: "zesty", label: "zesty", kind: "cloud", state: "connected" };
const machines = [mac, gcp, box, down, cloud];

describe("placementFromReply", () => {
  test("reads the relay's fields and drops anything else", () => {
    expect(
      placementFromReply({ pick: "gcp-3", local: false, overloaded: false, room: 5.9, localOver: "over its budget" }),
    ).toEqual({ pick: "gcp-3", local: false, overloaded: false, room: 5, localOver: "over its budget" });
    expect(placementFromReply({ pick: null, local: false })).toEqual({ local: false, overloaded: false });
    expect(placementFromReply({ pick: "x", room: -1, localOver: "" })).toEqual({
      pick: "x",
      local: false,
      overloaded: false,
    });
  });
  test("no reply (an older daemon or host) is no placement", () => {
    expect(placementFromReply(undefined)).toBeUndefined();
    expect(placementFromReply([])).toBeUndefined();
    expect(placementFromReply("gcp-3")).toBeUndefined();
  });
});

describe("autoChoice", () => {
  test("names placement's pick and its room", () => {
    expect(autoChoice({ pick: "gcp-3", local: false, overloaded: false, room: 5 }, machines)).toEqual({
      id: "gcp-3",
      label: "gcp-3",
      local: false,
      room: 5,
    });
  });
  test("a local pick is This Mac's row", () => {
    expect(autoChoice({ pick: "leo-mac", local: true, overloaded: false, room: 3 }, machines)).toEqual({
      id: "local",
      label: "leo-mac",
      local: true,
      room: 3,
    });
  });
  test("a Cloud machine placement picks is a pick too", () => {
    expect(autoChoice({ pick: "zesty", local: false, overloaded: false }, machines)?.id).toBe("zesty");
  });
  test("no row without a pick, for a full fleet, or for a machine no chat can start on", () => {
    expect(autoChoice(undefined, machines)).toBeUndefined();
    expect(autoChoice({ local: false, overloaded: false }, machines)).toBeUndefined();
    expect(autoChoice({ pick: "gcp-3", local: false, overloaded: true, room: 0 }, machines)).toBeUndefined();
    expect(autoChoice({ pick: "old-box", local: false, overloaded: false }, machines)).toBeUndefined();
    expect(autoChoice({ pick: "unlisted", local: false, overloaded: false }, machines)).toBeUndefined();
  });
});

describe("busyChoice", () => {
  const busy = {
    pick: "gcp-3",
    local: false,
    overloaded: false,
    room: 5,
    localOver: "over its budget (load1 29.8 >= 15)",
  };
  test("an over-budget Mac offers placement's pick, with the verdict", () => {
    expect(busyChoice(busy, machines, "local")).toEqual({
      id: "gcp-3",
      label: "gcp-3",
      why: "over its budget (load1 29.8 >= 15)",
    });
  });
  test("never while no other machine has room", () => {
    expect(busyChoice({ ...busy, overloaded: true }, machines, "local")).toBeUndefined();
    expect(busyChoice({ ...busy, pick: "leo-mac", local: true }, machines, "local")).toBeUndefined();
    expect(busyChoice({ ...busy, pick: "old-box" }, machines, "local")).toBeUndefined();
    const { room: _room, ...unread } = busy;
    expect(busyChoice(unread, machines, "local")).toBeUndefined();
    expect(busyChoice({ ...busy, room: 0 }, machines, "local")).toBeUndefined();
  });
  test("never for a quiet Mac, or once another machine is the pick", () => {
    const { localOver: _, ...quiet } = busy;
    expect(busyChoice(quiet, machines, "local")).toBeUndefined();
    expect(busyChoice(busy, machines, "build-box")).toBeUndefined();
  });
});

describe("lastRemoteMachine", () => {
  const sessions = [
    { cwd: "/home/leo/fun/cmux", peer: "build-box", activityAt: 100 },
    { cwd: "/home/leo/fun/cmux", peer: "gcp-3", activityAt: 300 },
    { cwd: "/home/leo/fun/other", peer: "build-box", activityAt: 900 },
    { cwd: "/Users/leo/fun/cmux", activityAt: 1000 },
    { cwd: "/home/leo/fun/cmux", peer: "old-box", activityAt: 2000 },
    { cwd: "/root/cmux", peer: "zesty", activityAt: 3000 },
  ];
  test("the machine this project's newest chat ran on, matched by the project's name", () => {
    expect(lastRemoteMachine(sessions, "/Users/leo/fun/cmux/", machines)).toBe("gcp-3");
    expect(lastRemoteMachine(sessions, "/Users/leo/fun/other", machines)).toBe("build-box");
  });
  test("never a machine that is down, a Cloud machine or this Mac", () => {
    expect(lastRemoteMachine(sessions.slice(3), "/Users/leo/fun/cmux", machines)).toBeUndefined();
  });
  test("none without a folder or a chat of the project on a machine", () => {
    expect(lastRemoteMachine(sessions, undefined, machines)).toBeUndefined();
    expect(lastRemoteMachine(sessions, "/Users/leo/fun/new", machines)).toBeUndefined();
  });
});
