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

// A send on a closed connection read the browser's own words ("Not sent: WebSocket is not open:
// readyState 3 (CLOSED)") or blamed the app ("The app refused this request"): both say the agent
// connection is not open, with Retry beside it (new-user journeys, F4).
test("a send on a closed connection says the connection is not open", () => {
  const closed = translate("prompt.notSent", { reason: translate("error.notOpen") });
  expect(failedSendText(new Error("WebSocket is not open: readyState 3 (CLOSED)"), false)).toBe(closed);
  expect(failedSendText(coded("transport.closed", { message: "socket closed" }), false)).toBe(closed);
  expect(failedSendText(coded("transport.closed"), true)).toBe(
    translate("prompt.stillNotSent", { reason: translate("error.notOpen") }),
  );
  // Another refusal keeps its words.
  expect(failedSendText(coded("transport.gesture_required"), false)).toBe(
    translate("prompt.notSent", { reason: translate("prompt.gestureReason") }),
  );
});
