import { expect, test } from "bun:test";
import { deviceChats, setDeviceChats } from "./deviceChats";
import { applyHostEvent } from "../pageHost";

test("the host's deviceChats push sets the list; malformed entries are dropped", () => {
  applyHostEvent({ kind: "deviceChats", value: [
    { key: "codex:1", harness: "codex", title: "Fix", updatedAt: 5 },
    { harness: "codex" },
    "junk",
    { key: "pi:2", harness: "pi", title: "", updatedAt: "x" },
  ] });
  expect(deviceChats()).toEqual([
    { key: "codex:1", harness: "codex", title: "Fix", updatedAt: 5 },
    { key: "pi:2", harness: "pi", updatedAt: 0 },
  ]);
  setDeviceChats(null);
  expect(deviceChats()).toEqual([]);
});
