import { expect, test } from "bun:test";
import { hoverBridgeMarker } from "./Tooltip";

test("AnchoredCard's marker preserves the bridge identity on a portal card", () => {
  expect(hoverBridgeMarker(7)).toEqual({ "data-cmux-hover-bridge": 7 });
  expect(hoverBridgeMarker(undefined)).toEqual({});
});
