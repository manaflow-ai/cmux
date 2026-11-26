import { expect, test } from "bun:test";
import type { RunMode } from "../sandboxRun";
import { newTabPin, pickNewTabPin } from "./newTabHybrid";

test("the New Tab control draws the page's Where pick", () => {
  expect(newTabPin({ autoPicked: true, mode: "persistent" })).toBe("auto");
  expect(newTabPin({ autoPicked: true, mode: "cloud" })).toBe("auto");
  expect(newTabPin({ autoPicked: false, mode: "cloud" })).toBe("cloud");
  expect(newTabPin({ autoPicked: false, mode: "persistent" })).toBe("local");
  expect(newTabPin({ autoPicked: false, mode: "sandboxed" })).toBe("local");
});

test("a pick writes through the Where rows: Hybrid is Auto, the pins are run modes", () => {
  const calls: string[] = [];
  const writes = {
    pickAuto: (on: boolean) => calls.push(`auto:${on}`),
    onMode: (mode: RunMode) => calls.push(`mode:${mode}`),
  };
  pickNewTabPin("auto", writes);
  pickNewTabPin("cloud", writes);
  pickNewTabPin("local", writes);
  expect(calls).toEqual(["auto:true", "auto:false", "mode:cloud", "auto:false", "mode:persistent"]);
});
