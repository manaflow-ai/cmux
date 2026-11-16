// Leo, 2026-11-12, at "Not sent yet: the agent service is taking longer than usual to answer. Your
// message is kept." over a turn whose prompt had gone through: no free transcript line for a send
// that only waited on the agent service. A failed row keeps its sentence (failedSendText).
import { expect, test } from "bun:test";
import { translate } from "./i18n";
import { failedSendText, heldSendNotice } from "./sendFailure";

const coded = (code: string, extra: Record<string, unknown> = {}) =>
  Object.assign(new Error(code), { code, origin: "native", ...extra });

test("a send that waited on the agent service says nothing in the transcript", () => {
  expect(heldSendNotice(coded("native.not_connected"))).toBeUndefined();
  expect(heldSendNotice(coded("native.timed_out", { reason: "interrupted", interrupted: true }))).toBeUndefined();
  expect(heldSendNotice(coded("native.timed_out"))).toBeUndefined();
});

test("a failed row still says why, with the same words as before", () => {
  expect(failedSendText(coded("native.not_connected"), false)).toBe(translate("prompt.failure.hostAway"));
});

test("a refusal the person can act on still says so", () => {
  expect(heldSendNotice({ reason: "trust.pending" })).toBe(translate("prompt.failure.trustPending"));
  expect(heldSendNotice({ reason: "message.too_large" })).toBe(translate("prompt.failure.tooLarge"));
  expect(heldSendNotice(coded("transport.intent_invalid"))).toBe(translate("prompt.failure.pane"));
});
