// A full-access refusal reads the same whether the pane's host or acpmux refused it. acpmux
// answers `-32000` with `data.reason: "full_access_off"` (start_mode.rs), which direct.ts keeps
// as `error.reason`; the pane's host answers `transport.full_access_off`. Both show the localized
// refusal, and both count as a host refusal a queued mode pick reports.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { errorMessage, isHostRefusal } from "../src/agent-session/acpmux/transportErrors";

const daemon = Object.assign(new Error("full-access modes are turned off in cmux Settings"), {
  code: -32000,
  reason: "full_access_off",
});
const pane = Object.assign(new Error("refused"), { code: "transport.full_access_off" });

test("acpmux's full_access_off reads as the localized refusal", () => {
  expect(errorMessage(daemon)).toBe(translate("transport.fullAccessOff"));
  expect(errorMessage(pane)).toBe(translate("transport.fullAccessOff"));
});

test("both refusals count as host refusals; other failures do not", () => {
  expect(isHostRefusal(daemon)).toBe(true);
  expect(isHostRefusal(pane)).toBe(true);
  expect(isHostRefusal(Object.assign(new Error("x"), { code: -32000, reason: "trust.pending" }))).toBe(false);
  expect(isHostRefusal(new Error("x"))).toBe(false);
});
