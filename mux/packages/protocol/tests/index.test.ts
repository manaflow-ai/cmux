import { expect, test } from "vite-plus/test";
import { isViewer, type Participant } from "../src/index.ts";

test("only the viewer's own human participant is the viewer", () => {
  const me: Participant = { kind: "human", id: "u1", displayName: "Lawrence" };
  const mux: Participant = { kind: "mux", id: "u1", displayName: "mux" };
  expect(isViewer(me, "u1")).toBe(true);
  expect(isViewer(me, "u2")).toBe(false);
  expect(isViewer(mux, "u1")).toBe(false);
});
