// A refused handshake offers Restart acpmux only when the host says so (another binary's acpmux
// holds this app's socket and the app may replace it); any other failure offers nothing new.
import { expect, test } from "bun:test";
import { offersAcpmuxRestart } from "./hostRetry";

test("only a refusal the host marked restartAcpmux offers Restart acpmux", () => {
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { restartAcpmux: true } })).toBe(true);
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { machineName: "mini" } })).toBe(false);
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { restartAcpmux: "yes" } })).toBe(false);
  expect(offersAcpmuxRestart({ code: "host_unavailable" })).toBe(false);
  expect(offersAcpmuxRestart(null)).toBe(false);
  expect(offersAcpmuxRestart("refused")).toBe(false);
});
