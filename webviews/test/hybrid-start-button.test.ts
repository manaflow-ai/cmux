// RFD 0078 "the start": the app's `place.start` (Rust's hybrid `Effect::Show`) reaches the three-state
// control, and the line after its name says nothing the start's own name already says.
import { expect, test } from "bun:test";
import { placementLine } from "../src/agent-session/acpmux/hybrid/HybridMounts";
import { HYBRID_START_STATES, hybridStartOf, startRunsHere } from "../src/agent-session/acpmux/hybrid/hybridModel";
import { placeOf } from "../src/agent-session/acpmux/place/placeModel";

const t = ((key: string) => key) as never;

test("every state Rust shows parses; none and junk draw nothing", () => {
  for (const cloud of HYBRID_START_STATES) expect(hybridStartOf({ cloud })).toEqual({ cloud });
  expect(hybridStartOf({ cloud: "none" })).toBeUndefined();
  expect(hybridStartOf({ cloud: "BOOTING" })).toBeUndefined();
  expect(hybridStartOf(undefined)).toBeUndefined();
  expect(hybridStartOf(["booting"])).toBeUndefined();
});

test("a reason rides only on failed", () => {
  expect(hybridStartOf({ cloud: "failed", reason: "quota" })).toEqual({ cloud: "failed", reason: "quota" });
  expect(hybridStartOf({ cloud: "booting", reason: "quota" })).toEqual({ cloud: "booting" });
});

test("place carries the start the app sends", () => {
  expect(placeOf({ mode: "cloud", at: "local", start: { cloud: "booting" } })?.start).toEqual({ cloud: "booting" });
  expect(placeOf({ mode: "cloud", at: "local" })?.start).toBeUndefined();
  expect(placeOf({ mode: "cloud", at: "local", start: { cloud: "none" } })?.start).toBeUndefined();
});

test("the chat runs here until it is live in Cloud", () => {
  for (const cloud of HYBRID_START_STATES) expect(startRunsHere({ cloud })).toBe(cloud !== "live");
});

test("during a start the name says where; live names the machine", () => {
  for (const cloud of ["booting", "ready", "moving", "failed"] as const) {
    expect(placementLine({ mode: "cloud", at: "local", cloudName: "atlas", start: { cloud } }, t)).toBeUndefined();
  }
  expect(placementLine({ mode: "cloud", at: "cloud", cloudName: "atlas", start: { cloud: "live" } }, t)).toBe("atlas");
});
